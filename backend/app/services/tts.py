"""TTS-Abstraktionsschicht. MVP: edge-tts (kostenlose deutsche Stimmen)."""
from __future__ import annotations

import asyncio
import logging
import os

from app.config import settings

log = logging.getLogger(__name__)


class TTSProvider:
    def synthesize(self, text: str, out_path: str, voice: str | None = None) -> str:
        raise NotImplementedError


VALID_VOICE_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

def _valid_voice(voice: str) -> bool:
    """edge-tts Stimmen sehen so aus: de-DE-KatjaNeural. Alles andere ablehnen."""
    return bool(voice) and set(voice) <= VALID_VOICE_CHARS and "-" in voice


class EdgeTTS(TTSProvider):
    def synthesize(self, text: str, out_path: str, voice: str | None = None) -> str:
        import edge_tts

        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        voice = voice or settings.tts_voice
        if not _valid_voice(voice):
            voice = settings.tts_voice  # Fallback auf .env-Stimme

        async def _run():
            communicate = edge_tts.Communicate(text, voice)
            await communicate.save(out_path)

        asyncio.run(_run())
        return out_path


def get_tts(db=None) -> TTSProvider:
    """db -> Stimme aus der settings-Tabelle (UI), sonst .env."""
    provider = settings.tts_provider
    if provider == "edge":
        return EdgeTTS()
    raise ValueError(f"Unbekannter TTS-Provider: {provider}")
