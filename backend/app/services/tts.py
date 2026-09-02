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


class EdgeTTS(TTSProvider):
    def synthesize(self, text: str, out_path: str, voice: str | None = None) -> str:
        import edge_tts

        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        voice = voice or settings.tts_voice

        async def _run():
            communicate = edge_tts.Communicate(text, voice)
            await communicate.save(out_path)

        asyncio.run(_run())
        return out_path


def get_tts() -> TTSProvider:
    if settings.tts_provider == "edge":
        return EdgeTTS()
    raise ValueError(f"Unbekannter TTS-Provider: {settings.tts_provider}")
