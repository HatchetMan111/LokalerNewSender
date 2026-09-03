"""Einstellungen: LLM/TTS-Provider, Stimme, Intervalle – live aus der DB.

Die .env liefert die Defaults; Werte aus der settings-Tabelle (UI) gewinnen.
So kann man in der Oberfläche umschalten, ohne Container neu zu starten.
"""
from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from app.config import settings as env_settings
from app.models import Setting

_cache: dict[str, tuple[Any, float]] = {}
_CACHE_TTL = 5.0


def get_setting(db: Session, key: str, default: Any = None) -> Any:
    """Liest eine Einstellung (DB schlägt .env-Default). Mit Mini-Cache."""
    import time
    now = time.time()
    if key in _cache and now - _cache[key][1] < _CACHE_TTL:
        return _cache[key][0]
    row = db.get(Setting, key)
    value = row.value if row and row.value is not None else default
    _cache[key] = (value, now)
    return value


def clear_cache() -> None:
    _cache.clear()


def llm_provider(db: Session) -> str:
    return get_setting(db, "llm_provider", env_settings.llm_provider)


def openai_model(db: Session) -> str:
    return get_setting(db, "openai_model", env_settings.openai_model)


def tts_voice(db: Session) -> str:
    return get_setting(db, "tts_voice", env_settings.tts_voice)


def import_interval_minutes(db: Session) -> int:
    try:
        return int(get_setting(db, "import_interval_minutes", env_settings.import_interval_minutes))
    except (TypeError, ValueError):
        return env_settings.import_interval_minutes


def target_duration(db: Session) -> int:
    try:
        return int(get_setting(db, "target_duration", env_settings.target_duration))
    except (TypeError, ValueError):
        return env_settings.target_duration
