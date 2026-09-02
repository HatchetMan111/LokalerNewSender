"""Datei- und Pfadverwaltung für /data (media, projects, exports, archive)."""
from __future__ import annotations

import os
import re

from app.config import settings


def ensure_dirs() -> None:
    for sub in ("media/images", "media/video", "media/audio", "media/generated", "projects", "exports", "archive"):
        os.makedirs(os.path.join(settings.data_dir, sub), exist_ok=True)


def slugify(text: str) -> str:
    text = text.lower().strip()
    text = re.sub(r"ä", "ae", text)
    text = re.sub(r"ö", "oe", text)
    text = re.sub(r"ü", "ue", text)
    text = re.sub(r"ß", "ss", text)
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")[:80] or "sendung"


def episode_dir(episode_id: int) -> str:
    d = os.path.join(settings.data_dir, "projects", f"episode-{episode_id}")
    os.makedirs(d, exist_ok=True)
    return d


def voice_path(episode_id: int, item_id: int) -> str:
    return os.path.join(episode_dir(episode_id), f"voice-{item_id:03d}.mp3")


def video_path(episode_id: int, item_id: int) -> str:
    return os.path.join(episode_dir(episode_id), f"segment-{item_id:03d}.mp4")


def export_paths(slug: str) -> dict:
    base = os.path.join(settings.data_dir, "exports", slug)
    os.makedirs(base, exist_ok=True)
    return {
        "dir": base,
        "video": os.path.join(base, f"{slug}.mp4"),
        "audio": os.path.join(base, f"{slug}.mp3"),
        "json": os.path.join(base, f"{slug}.json"),
    }
