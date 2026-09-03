"""Runtime-Einstellungen aus der settings-Tabelle (UI), Fallback .env.

Registry-Muster: PROVIDER definieren, welche Anbieter & Optionen die UI
anbietet; get_*() lesen den aktuell gewählten Wert (DB schlägt .env).
"""
from __future__ import annotations

import time
from typing import Any

from sqlalchemy.orm import Session

from app.config import settings as env_settings
from app.models import Setting

_cache: dict[str, tuple[Any, float]] = {}
_CACHE_TTL = 5.0


def get_setting(db: Session, key: str, default: Any = None) -> Any:
    cached = _cache.get(key)
    now = time.time()
    if cached and now - cached[1] < _CACHE_TTL:
        return cached[0]
    row = db.get(Setting, key)
    value = row.value if row and row.value not in (None, "") else default
    if value is None:
        value = default
    _cache[key] = (value, now)
    return value


def clear_cache() -> None:
    _cache.clear()


# --------------------------------------------------------------------------
# Provider-Registries (Was die UI anbietet)
# --------------------------------------------------------------------------
LLM_PROVIDERS: dict[str, dict] = {
    "mock": {
        "label": "Mock (ohne API-Key)",
        "needs": [],
        "models": ["mock"],
    },
    "openai": {
        "label": "OpenAI",
        "needs": ["OPENAI_API_KEY"],
        "models": ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "o4-mini"],
    },
    "openrouter": {
        "label": "OpenRouter",
        "needs": ["OPENROUTER_API_KEY"],
        "models": [
            "openai/gpt-4o-mini", "openai/gpt-4o",
            "anthropic/claude-3.5-haiku", "anthropic/claude-3.5-sonnet",
            "meta-llama/llama-3.1-8b-instruct", "mistralai/mistral-small",
            "google/gemini-2.0-flash-001",
        ],
    },
    "anthropic": {
        "label": "Anthropic",
        "needs": ["ANTHROPIC_API_KEY"],
        "models": ["claude-3-5-haiku-latest", "claude-3-5-sonnet-latest", "claude-3-opus-latest"],
    },
    "ollama": {
        "label": "Ollama (lokal)",
        "needs": ["OLLAMA_BASE_URL"],
        "models": ["llama3.1", "llama3.1:8b", "mistral", "qwen2.5:7b", "gemma2:9b"],
    },
    "custom": {
        "label": "Custom (OpenAI-kompatibel)",
        "needs": ["LLM_BASE_URL"],
        "models": [],
    },
}

TTS_PROVIDERS: dict[str, dict] = {
    "edge": {
        "label": "Edge-TTS (kostenlos)",
        "needs": [],
        "voices": [
            "de-DE-KatjaNeural", "de-DE-ConradNeural", "de-DE-AmalaNeural",
            "de-DE-BerndNeural", "de-DE-ElkeNeural", "de-DE-KasperNeural",
            "de-DE-LeneNeural", "de-DE-RainerNeural",
        ],
    },
    "openai": {
        "label": "OpenAI Speech (tts-1)",
        "needs": ["OPENAI_API_KEY"],
        "voices": ["alloy", "echo", "fable", "onyx", "nova", "shimmer"],
    },
    "localai": {
        "label": "LocalAI / OpenAI-kompatibel",
        "needs": ["TTS_BASE_URL"],
        "voices": ["tts-1", "de"],
    },
}

VIDEO_RESOLUTIONS = ["1920x1080", "1280x720", "1080x1920", "720x1280", "3840x2160"]
VIDEO_STYLES = ["news-dark", "news-light", "minimal"]
RENDERER_BACKENDS = {
    "ffmpeg": "FFmpeg (lokal, Standard)",
    "webhook": "Externer Renderer (Webhook, POST Production JSON)",
}


# --------------------------------------------------------------------------
# Convenience-Getter (DB-Wert > .env-Default)
# --------------------------------------------------------------------------
def _env(name: str) -> Any:
    return getattr(env_settings, name, "")


def llm_provider(db: Session) -> str:
    return get_setting(db, "llm_provider", env_settings.llm_provider)


def llm_model(db: Session) -> str:
    p = llm_provider(db)
    defaults = {
        "openai": env_settings.openai_model,
        "openrouter": env_settings.openrouter_model,
        "anthropic": env_settings.anthropic_model,
        "ollama": env_settings.ollama_model,
        "custom": env_settings.llm_model,
    }
    return get_setting(db, "llm_model", defaults.get(p, p))


def llm_needs(db: Session) -> list[str]:
    return LLM_PROVIDERS.get(llm_provider(db), {}).get("needs", [])


def llm_ready(db: Session) -> tuple[bool, str]:
    """Prüft, ob für den gewählten Provider alle Secrets vorhanden sind."""
    missing = [n for n in llm_needs(db) if not _env(n)]
    if missing:
        return False, f"In .env fehlt: {', '.join(missing)}"
    return True, ""


def tts_provider(db: Session) -> str:
    return get_setting(db, "tts_provider", env_settings.tts_provider)


def tts_voice(db: Session) -> str:
    return get_setting(db, "tts_voice", env_settings.tts_voice)


def tts_model(db: Session) -> str:
    return get_setting(db, "tts_model", env_settings.tts_model)


def tts_base_url(db: Session) -> str:
    return get_setting(db, "tts_base_url", env_settings.tts_base_url)


def tts_ready(db: Session) -> tuple[bool, str]:
    p = tts_provider(db)
    needs = TTS_PROVIDERS.get(p, {}).get("needs", [])
    missing = [n for n in needs if n and not _env(n)]
    if missing:
        return False, f"In .env fehlt: {', '.join(missing)}"
    return True, ""


def video_resolution(db: Session) -> str:
    return get_setting(db, "video_resolution", env_settings.video_resolution)


def video_style(db: Session) -> str:
    return get_setting(db, "video_style", env_settings.video_style)


def renderer_backend(db: Session) -> str:
    return get_setting(db, "renderer_backend", env_settings.renderer_backend)


def renderer_webhook_url(db: Session) -> str:
    return get_setting(db, "renderer_webhook_url", env_settings.renderer_webhook_url)


def subtitles_enabled(db: Session) -> bool:
    return str(get_setting(db, "subtitles", "off")).strip().lower() in ("on", "1", "true", "yes")


def import_interval_minutes(db: Session) -> int:
    try:
        return int(get_setting(db, "import_interval_minutes", env_settings.import_interval_minutes))
    except (TypeError, ValueError):
        return env_settings.import_interval_minutes


def target_duration(db: Session) -> int:
    try:
        return int(get_setting(db, "target_duration", 600))
    except (TypeError, ValueError):
        return 600
