"""Video-/Audio-Renderer.

Backends:
  ffmpeg   – lokaler FFmpeg-Schnittplatz (Standard): Titelkarten mit
             Headline + Lower Third je Stil, Voice-Audio, Concat zu MP4/MP3
  webhook  – externer Render-Service: bekommt das komplette Production
             JSON via POST und liefert MP4/MP3 zurück (z.B. GPU-Host,
             Spezial-Renderer, Cloud-Service)

Stile (video_style): news-dark | news-light | minimal
Auflösungen: 16:9 (1920x1080, 1280x720, 4K) und 9:16 vertikal (1080x1920,
720x1280) für Shorts/Reels/TikTok.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import urllib.request

import httpx

from app.config import settings
from app.services.storage import export_paths

log = logging.getLogger(__name__)

FPS = settings.video_fps

STYLES: dict[str, dict] = {
    "news-dark": {
        "bg": "#101820", "bar": "#0b3d91", "bar_alpha": 0.75,
        "title_color": "white", "sub_color": "white", "textcolor": "white",
    },
    "news-light": {
        "bg": "#f4f6f9", "bar": "#2563eb", "bar_alpha": 0.85,
        "title_color": "#0b1b33", "sub_color": "#0b1b33", "textcolor": "#101820",
    },
    "minimal": {
        "bg": "#000000", "bar": None, "bar_alpha": 0,
        "title_color": "white", "sub_color": "#9aa7b5", "textcolor": "white",
    },
}

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def _esc(text: str) -> str:
    return text.replace("\\", "").replace(":", "\\:").replace("'", "").replace("%", "")


def _ffprobe_duration(path: str) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
         "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True,
    )
    return float(out.stdout.strip())


def _style(resolution: str, style_name: str) -> dict:
    width, height = (int(x) for x in resolution.split("x"))
    s = dict(STYLES.get(style_name, STYLES["news-dark"]))
    vertical = height > width
    # Skalierung der Typo für kleine Auflösungen / Vertikal
    scale = width / 1920 if not vertical else width / 1080
    s.update({
        "width": width, "height": height, "vertical": vertical,
        "title_size": int(58 * scale), "sub_size": int(34 * scale),
    })
    if vertical:
        s["title_y"] = "h*0.80"
        s["sub_y"] = "h*0.88"
        s["bar_y"] = int(height * 0.74)
        s["bar_h"] = int(height * 0.16)
    else:
        s["title_y"] = "h*0.75"
        s["sub_y"] = "h*0.85"
        s["bar_y"] = int(height * 0.72)
        s["bar_h"] = int(height * 0.18)
    return s


def _render_segment(video_out: str, audio_path: str, headline: str, sub: str,
                    style_name: str, resolution: str) -> str:
    s = _style(resolution, style_name)
    duration = max(_ffprobe_duration(audio_path) + 1.0, 3.0)

    parts = [f"drawbox=x=0:y=0:w={s['width']}:h={s['height']}:color={s['bg']}:t=fill"]
    if s.get("bar"):
        parts.append(
            f"drawbox=x=0:y={s['bar_y']}:w={s['width']}:h={s['bar_h']}:"
            f"color={s['bar']}@{s['bar_alpha']}:t=fill"
        )
    parts.append(
        f"drawtext=fontfile={FONT_BOLD}:text='{_esc(headline)}':"
        f"fontcolor={s['title_color']}:fontsize={s['title_size']}:"
        f"x=(w-text_w)/2:y={s['title_y']}"
    )
    parts.append(
        f"drawtext=fontfile={FONT}:text='{_esc(sub)}':"
        f"fontcolor={s['sub_color']}:fontsize={s['sub_size']}:"
        f"x=(w-text_w)/2:y={s['sub_y']}"
    )
    cmd = [
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", f"color=c={s['bg']}:s={s['width']}x{s['height']}:r={FPS}:d={duration}",
        "-i", audio_path,
        "-vf", ",".join(parts),
        "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "160k", "-shortest",
        video_out,
    ]
    subprocess.run(cmd, capture_output=True, text=True, check=True)
    return video_out


def _concat(files: list[str], out_path: str, copy: bool = False) -> str:
    listfile = out_path + ".txt"
    with open(listfile, "w") as fh:
        for f in files:
            fh.write(f"file '{f}'\n")
    cmd = ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", listfile]
    if copy:
        cmd += ["-c", "copy", out_path]
    else:
        cmd += ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "160k", out_path]
    subprocess.run(cmd, capture_output=True, text=True, check=True)
    os.unlink(listfile)
    return out_path


def _render_webhook(production: dict, paths: dict, webhook_url: str) -> None:
    """Externer Renderer: POST Production JSON, Antwort als Dateien speichern."""
    resp = httpx.post(webhook_url, json=production, timeout=1800)
    resp.raise_for_status()
    content_type = resp.headers.get("content-type", "")
    if "json" in content_type:
        data = resp.json()
        video_b64 = data.get("video_b64") or data.get("video")
        audio_b64 = data.get("audio_b64") or data.get("audio")
        if video_b64 and audio_b64:
            import base64
            with open(paths["video"], "wb") as fh:
                fh.write(base64.b64decode(video_b64))
            with open(paths["audio"], "wb") as fh:
                fh.write(base64.b64decode(audio_b64))
            return
        raise RuntimeError("Webhook-Antwort ohne video_b64/audio_b64")
    if "video" in content_type:
        with open(paths["video"], "wb") as fh:
            fh.write(resp.content)
        raise RuntimeError("Webhook lieferte nur Video – Audio-Download separat implementieren")
    raise RuntimeError(f"Webhook-Antworttyp nicht unterstützt: {content_type}")


def render_episode(episode, items, *, backend: str = "ffmpeg", style: str | None = None,
                   resolution: str | None = None, webhook_url: str = "") -> dict:
    """Rendert die Sendung. Rückgabe: Pfade + Production JSON (als Dict)."""
    style = style or settings.video_style
    resolution = resolution or settings.video_resolution
    slug = f"{episode.city.name.lower().replace(' ', '-').replace('ä', 'ae').replace('ö', 'oe').replace('ü', 'ue')}-{episode.date}" \
        if episode.city else f"episode-{episode.id}"
    paths = export_paths(slug)

    production = {
        "episode": {"id": episode.id, "title": episode.title, "duration": episode.target_duration},
        "render": {"backend": backend, "style": style, "resolution": resolution, "fps": FPS},
        "segments": [
            {
                "type": item.seg_type,
                "position": item.position,
                "duration": item.duration,
                "headline": item.headline,
                "spoken_text": item.script,
                "lower_third": item.lower_third,
                "voice_file": item.voice_file,
            }
            for item in items
        ],
    }
    with open(paths["json"], "w", encoding="utf-8") as fh:
        json.dump(production, fh, ensure_ascii=False, indent=2)

    if backend == "webhook":
        if not webhook_url:
            raise RuntimeError("renderer_webhook_url nicht gesetzt (Einstellungen)")
        _render_webhook(production, paths, webhook_url)
        return {"video": paths["video"], "audio": paths["audio"], "json": paths["json"], "production": production}

    # ---- FFmpeg-Backend ----
    segments = []
    for item in items:
        if not item.voice_file or not os.path.exists(item.voice_file):
            raise RuntimeError(f"Voice-Datei fehlt für Item {item.id}")
        headline = item.headline or "Nachricht"
        sub = episode.city.name if episode.city else "Lokal"
        seg_video = os.path.join(paths["dir"], f"segment-{item.id:03d}.mp4")
        _render_segment(seg_video, item.voice_file, headline, sub, style, resolution)
        item.video_file = seg_video
        segments.append(seg_video)

    video_file = _concat(segments, paths["video"])
    audio_file = _concat([i.voice_file for i in items if i.voice_file], paths["audio"], copy=True)

    return {"video": video_file, "audio": audio_file, "json": paths["json"], "production": production}
