"""TTS-Abstraktionsschicht.

Anbieter:
  edge     – kostenlose Microsoft-Stimmen (Standard, kein Key)
  openai   – OpenAI Speech API (alloy, echo, nova, ...)
  localai  – jeder OpenAI-kompatible Speech-Endpunkt (LocalAI, vLLM, ...)
"""
from __future__ import annotations

import asyncio
import logging
import os

import httpx

from app.config import settings

log = logging.getLogger(__name__)

VALID_VOICE_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")


def _valid_voice(voice: str) -> bool:
    """edge/openai-Stimmen: nur Buchstaben, Zahlen, Bindestrich."""
    return bool(voice) and set(voice) <= VALID_VOICE_CHARS and "-" in voice or voice in ("alloy", "echo", "fable", "onyx", "nova", "shimmer", "tts-1", "de")


class TTSProvider:
    def synthesize(self, text: str, out_path: str, voice: str | None = None) -> str:
        raise NotImplementedError


class EdgeTTS(TTSProvider):
    name = "edge"

    def synthesize(self, text: str, out_path: str, voice: str | None = None) -> str:
        import edge_tts

        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        voice = voice if (voice and _valid_voice(voice)) else settings.tts_voice
        if not _valid_voice(voice):
            voice = "de-DE-KatjaNeural"

        async def _run():
            communicate = edge_tts.Communicate(text, voice)
            await communicate.save(out_path)

        asyncio.run(_run())
        return out_path


class OpenAISpeech(TTSProvider):
    """OpenAI Speech / jeder OpenAI-kompatible /v1/audio/speech-Endpunkt."""

    name = "openai"

    def __init__(self, base_url: str = "", api_key: str = ""):
        self.base_url = (base_url or "").rstrip("/") or "https://api.openai.com/v1"
        self.api_key = api_key

    def synthesize(self, text: str, out_path: str, voice: str | None = None) -> str:
        voice = voice if (voice and _valid_voice(voice)) else "alloy"
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        resp = httpx.post(
            f"{self.base_url}/audio/speech",
            headers=headers,
            json={"model": settings.tts_model, "input": text, "voice": voice,
                  "response_format": "mp3"},
            timeout=180,
        )
        resp.raise_for_status()
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "wb") as fh:
            fh.write(resp.content)
        return out_path


def get_tts(db=None) -> TTSProvider:
    """db -> Anbieter aus der settings-Tabelle (UI), sonst .env."""
    provider = settings.tts_provider
    base_url = ""
    if db is not None:
        from app.services import settings_svc
        provider = settings_svc.tts_provider(db)
        base_url = settings_svc.tts_base_url(db)

    if provider == "edge":
        return EdgeTTS()
    if provider == "openai":
        if not settings.openai_api_key:
            log.warning("OPENAI_API_KEY leer – TTS fällt auf edge zurück")
            return EdgeTTS()
        return OpenAISpeech(base_url, settings.openai_api_key)
    if provider == "localai":
        if not base_url and not settings.tts_base_url:
            log.warning("TTS_BASE_URL leer – TTS fällt auf edge zurück")
            return EdgeTTS()
        return OpenAISpeech(base_url or settings.tts_base_url, settings.llm_api_key)
    log.warning("Unbekannter TTS-Provider '%s' – nutze edge", provider)
    return EdgeTTS()
