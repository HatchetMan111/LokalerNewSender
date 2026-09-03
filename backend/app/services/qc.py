"""Qualitätskontrolle nach dem Rendern (video-use-Prinzip: Self-Eval).

Statt blind zu vertrauen, prüft die Pipeline das fertige MP4/MP3:
Streams vorhanden? Auflösung korrekt? Audio nicht stumm? Dauer plausibel?
Schlägt ein Check fehl, geht die Episode auf FAILED (mit konkretem Grund)
statt ein kaputtes Video auszuliefern – `generate` startet dann neu.
"""
from __future__ import annotations

import logging
import os
import re
import subprocess

log = logging.getLogger(__name__)

MIN_FILE_BYTES = 10_000


def _probe(path: str, entries: str) -> str:
    out = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", entries,
         "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def _max_volume_db(audio_path: str) -> float | None:
    """Spitzenpegel in dB (None = nicht ermittelbar, -inf = Stille)."""
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", audio_path,
         "-af", "volumedetect", "-f", "null", "/dev/null"],
        capture_output=True, text=True,
    )
    m = re.search(r"max_volume:\s*(-?[\d.]+|-inf)\s*dB", proc.stderr)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def check_episode(video_path: str, audio_path: str, expected_resolution: str = "",
                  expected_duration: float = 0.0) -> dict:
    """Prüft MP4 + MP3. Rückgabe: {"passed": bool, "checks": [{name, ok, detail}]}."""
    checks: list[dict] = []

    def add(name: str, ok: bool, detail: str = ""):
        checks.append({"name": name, "ok": bool(ok), "detail": str(detail)})

    # 1) Dateien vorhanden + Mindestgröße
    for label, path in (("Video-Datei", video_path), ("Audio-Datei", audio_path)):
        exists = os.path.exists(path)
        size = os.path.getsize(path) if exists else 0
        add(f"{label} vorhanden", exists and size >= MIN_FILE_BYTES, f"{size} Bytes")

    if not all(c["ok"] for c in checks):
        return {"passed": False, "checks": checks}

    # 2) Video-Stream: Codec + Auflösung
    try:
        streams = _probe(video_path, "stream=codec_name,width,height").splitlines()
        video_streams = [s for s in streams if s.startswith("h264")]
        add("Video-Codec h264", bool(video_streams), streams[0] if streams else "kein Stream")
        if expected_resolution and video_streams:
            try:
                exp_w, exp_h = expected_resolution.split("x")
                got = video_streams[0].split(",")
                add("Auflösung korrekt", got[1:3] == [exp_w, exp_h],
                    f"erwartet {expected_resolution}, ist {','.join(got[1:3])}")
            except (IndexError, ValueError):
                add("Auflösung korrekt", False, f"erwartet {expected_resolution}")
        audio_in_mp4 = any(s.startswith(("aac", "mp3")) for s in streams)
        add("Tonspur im Video", audio_in_mp4, "")
    except subprocess.CalledProcessError as exc:
        add("Video-Streams lesbar", False, str(exc)[:120])

    # 3) Dauer plausibel
    try:
        v_dur = float(_probe(video_path, "format=duration").splitlines()[0])
        a_dur = float(_probe(audio_path, "format=duration").splitlines()[0])
        add("Video-Dauer > 10s", v_dur > 10, f"{v_dur:.1f}s")
        add("Audio-Dauer ≈ Video-Dauer", abs(v_dur - a_dur) <= 5.0,
            f"Video {v_dur:.1f}s / Audio {a_dur:.1f}s")
        if expected_duration > 0:
            add("Dauer ≈ Sprecher-Summe", abs(v_dur - expected_duration) <= 15.0,
                f"erwartet ~{expected_duration:.0f}s, ist {v_dur:.1f}s")
    except (subprocess.CalledProcessError, ValueError, IndexError) as exc:
        add("Dauer prüfbar", False, str(exc)[:120])

    # 4) Audio nicht stumm
    peak = _max_volume_db(audio_path)
    if peak is None:
        add("Audio-Pegel messbar", False, "volumedetect ohne Ergebnis")
    else:
        add("Audio nicht stumm", peak > -70.0, f"Peak {peak:.1f} dB")

    passed = all(c["ok"] for c in checks)
    return {"passed": passed, "checks": checks}
