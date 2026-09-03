"""AI-Abstraktionsschicht.

Die Pipeline kennt nur `llm.generate(...)`, niemals einen konkreten Anbieter.
Neue Provider (Anthropic, Google, lokales Modell) implementieren dieselbe Klasse.
"""
from __future__ import annotations

import json
import logging
import re

import httpx

from app.config import settings

log = logging.getLogger(__name__)


class LLMProvider:
    def generate(self, prompt: str, system: str = "") -> str:
        raise NotImplementedError

    name = "mock"


class MockLLM(LLMProvider):
    """Template-basierter Fallback, funktioniert ohne API-Key.

    Erzeugt brauchbare deutsche Sprechertexte aus Titel + Zusammenfassung.
    """

    name = "mock"

    def generate(self, prompt: str, system: str = "") -> str:
        payload = json.loads(prompt)
        headline = payload.get("headline", "")
        summary = payload.get("summary", "") or headline
        city = payload.get("city", "")
        location = payload.get("location", city)

        lead = summary.split(".")[0].strip() or headline
        text = (
            f"Aus {location}: {headline}. "
            f"{lead}. "
            f"Darüber berichten wir Ihnen heute aus {city}. "
            "Wir bleiben für Sie dran und halten Sie auf dem Laufenden."
        )
        return text


class OpenAILLM(LLMProvider):
    name = "openai"

    def __init__(self, model: str | None = None):
        self.model = model or settings.openai_model

    def generate(self, prompt: str, system: str = "") -> str:
        if not settings.openai_api_key:
            log.warning("OPENAI_API_KEY leer – falle auf Mock-Provider zurück")
            return MockLLM().generate(prompt, system)
        resp = httpx.post(
            "https://api.openai.com/v1/chat/completions",
            headers={"Authorization": f"Bearer {settings.openai_api_key}"},
            json={
                "model": self.model,
                "messages": [
                    {"role": "system", "content": system or "Du bist ein Redakteur für lokale Nachrichten."},
                    {"role": "user", "content": prompt},
                ],
                "temperature": 0.6,
            },
            timeout=120,
        )
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]


def get_llm(db=None) -> LLMProvider:
    """db -> Provider/Modell aus der settings-Tabelle (UI), sonst .env."""
    provider = settings.llm_provider
    model = settings.openai_model
    if db is not None:
        from app.services import settings_svc
        provider = settings_svc.llm_provider(db)
        model = settings_svc.openai_model(db)
    if provider == "openai":
        return OpenAILLM(model)
    return MockLLM()


def parse_json_loose(text: str) -> dict | list | None:
    """Extrahiert JSON aus LLM-Antwort (tolleriert ```-Blöcke)."""
    text = text.strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if m:
        text = m.group(1).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None
