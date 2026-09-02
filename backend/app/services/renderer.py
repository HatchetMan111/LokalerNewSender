"""Video-/Audio-Renderer.

Der Renderer erhält kein Rohmaterial, sondern das strukturierte Production
JSON: Segmente mit Sprechaudio, Headline und Lower Third. FFmpeg agiert als
virtueller Fernsehschnittplatz:

    Segment = Titelkarte (drawtext) + Voice-Audio  ->  concat  ->  MP4/MP3
"""
from __future__ import annotations

import json
import logging
import os
import subprocess

from app.config import settings
from app.services.storage import export_paths

log = logging.getLogger(__name__)

WIDTH, HEIGHT = (int(x) for x in settings.video_resolution.split("x"))
FPS = settings.video_fps

FONT = "DejaVuSans"


def _ffprobe_duration(path: str) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
         "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True,
    )
    return float(out.stdout.strip())


def _esc(text: str) -> str:
    return text.replace("\\", "").replace(":", "\\:").replace("'", "").replace("%", "")


def _render_segment(video_out: str, audio_path: str, headline: str, sub: str) -> str:
    """Erzeugt ein Segment: Titelkarte + Sprechaudio."""
    duration = max(_ffprobe_duration(audio_path) + 1.0, 3.0)
    vf = (
        f"drawbox=x=0:y=0:w={WIDTH}:h={HEIGHT}:color=#101820:t=fill,"
        f"drawbox=x=0:y={int(HEIGHT * 0.72)}:w={WIDTH}:h={int(HEIGHT * 0.18)}:color=#0b3d91@0.75:t=fill,"
        f"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:"
        f"text='{_esc(headline)}':fontcolor=white:fontsize=58:"
        f"x=(w-text_w)/2:y=h*0.75,"
        f"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:"
        f"text='{_esc(sub)}':fontcolor=white:fontsize=34:"
        f"x=(w-text_w)/2:y=h*0.85"
    )
    cmd = [
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", f"color=c=#101820:s={WIDTH}x{HEIGHT}:r={FPS}:d={duration}",
        "-i", audio_path,
        "-vf", vf,
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


def render_episode(episode, items) -> dict:
    """Rendert alle Segmente zu MP4 + MP3 und schreibt das Production JSON.

    Return: {"video": ..., "audio": ..., "json": ...} (absolute Pfade)
    """
    slug = f"{episode.city.name.lower().replace(' ', '-')}-{episode.date}" if episode.city else f"episode-{episode.id}"
    paths = export_paths(slug)

    segments = []
    for item in items:
        if not item.voice_file or not os.path.exists(item.voice_file):
            raise RuntimeError(f"Voice-Datei fehlt für Item {item.id}")
        headline = item.headline or "Nachricht"
        sub = episode.city.name if episode.city else "Lokal"
        seg_video = _render_segment(item.video_file or video_tmp(item.id), item.voice_file, headline, sub)
        segments.append(seg_video)

    video_file = _concat(segments, paths["video"])
    audio_file = _concat([i.voice_file for i in items if i.voice_file], paths["audio"], copy=True)

    production = {
        "episode": {"id": episode.id, "title": episode.title, "duration": episode.target_duration},
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

    return {"video": video_file, "audio": audio_file, "json": paths["json"]}


def video_tmp(item_id: int) -> str:
    import tempfile
    return os.path.join(tempfile.gettempdir(), f"segment-{item_id}.mp4")
