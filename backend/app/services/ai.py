"""LLM-Abstraktionsschicht (Adapter-Pattern).

Die Pipeline kennt nur `llm.generate(...)` – welcher Anbieter dahinter
steht, ist reine Konfiguration (UI/settings-Tabelle oder .env).

Unterstützte Anbieter:
  mock        – Template-Fallback, ohne API-Key
  openai      – offizielle API
  openrouter  – Aggregator (openai/gpt-4o-mini, anthropic/…, meta-llama/…)
  anthropic   – Claude (eigene Nachrichten-API)
  ollama      – lokale Instanz (z.B. auf anderem Rechner im Netz)
  custom      – jeder OpenAI-kompatible Endpunkt (LocalAI, vLLM, ...)
"""
from __future__ import annotations

import json
import logging
import re

import httpx

from app.config import settings

log = logging.getLogger(__name__)


class LLMProvider:
    name = "mock"
    model = "mock"

    def generate(self, prompt: str, system: str = "") -> str:
        raise NotImplementedError


class MockLLM(LLMProvider):
    """Template-basierter Fallback – funktioniert ohne jeden API-Key."""

    name = "mock"
    model = "mock"

    def generate(self, prompt: str, system: str = "") -> str:
        payload = json.loads(prompt)
        headline = payload.get("headline", "")
        summary = payload.get("summary", "") or headline
        city = payload.get("city", "")
        location = payload.get("location", city)

        lead = summary.split(".")[0].strip() or headline
        return (
            f"Aus {location}: {headline}. "
            f"{lead}. "
            f"Darüber berichten wir Ihnen heute aus {city}. "
            "Wir bleiben für Sie dran und halten Sie auf dem Laufenden."
        )


class OpenAICompatible(LLMProvider):
    """Basisklasse: chat/completions im OpenAI-Format.

    Deckt openai, openrouter, ollama und custom ab – unterscheiden sich nur
    in Base-URL, Header und Modell-Namen.
    """

    def __init__(self, model: str, base_url: str = "", api_key: str = "",
                 extra_headers: dict | None = None):
        self.model = model
        self.base_url = base_url.rstrip("/") if base_url else "https://api.openai.com/v1"
        self.api_key = api_key
        self.extra_headers = extra_headers or {}

    def generate(self, prompt: str, system: str = "") -> str:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        headers.update(self.extra_headers)
        resp = httpx.post(
            f"{self.base_url}/chat/completions",
            headers=headers,
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


class OpenAI(OpenAICompatible):
    name = "openai"

    def __init__(self, model: str | None = None):
        if not settings.openai_api_key:
            raise RuntimeError("OPENAI_API_KEY nicht gesetzt (.env)")
        super().__init__(model or settings.openai_model,
                         "https://api.openai.com/v1", settings.openai_api_key)


class OpenRouter(OpenAICompatible):
    name = "openrouter"

    def __init__(self, model: str | None = None):
        if not settings.openrouter_api_key:
            raise RuntimeError("OPENROUTER_API_KEY nicht gesetzt (.env)")
        super().__init__(model or settings.openrouter_model,
                         "https://openrouter.ai/api/v1", settings.openrouter_api_key,
                         extra_headers={"HTTP-Referer": "http://local-news", "X-Title": "Local News Platform"})


class Ollama(OpenAICompatible):
    name = "ollama"

    def __init__(self, model: str | None = None):
        if not settings.ollama_base_url:
            raise RuntimeError("OLLAMA_BASE_URL nicht gesetzt (.env), z.B. http://192.168.178.50:11434")
        super().__init__(model or settings.ollama_model,
                         settings.ollama_base_url.rstrip("/").removesuffix("/v1"), "")


class CustomLLM(OpenAICompatible):
    name = "custom"

    def __init__(self, model: str | None = None):
        if not settings.llm_base_url:
            raise RuntimeError("LLM_BASE_URL nicht gesetzt (.env)")
        super().__init__(model or settings.llm_model or "custom",
                         settings.llm_base_url, settings.llm_api_key)


class Anthropic(LLMProvider):
    name = "anthropic"

    def __init__(self, model: str | None = None):
        if not settings.anthropic_api_key:
            raise RuntimeError("ANTHROPIC_API_KEY nicht gesetzt (.env)")
        self.model = model or settings.anthropic_model

    def generate(self, prompt: str, system: str = "") -> str:
        resp = httpx.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": settings.anthropic_api_key,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            },
            json={
                "model": self.model,
                "max_tokens": 600,
                "system": system or "Du bist ein Redakteur für lokale Nachrichten.",
                "messages": [{"role": "user", "content": prompt}],
            },
            timeout=120,
        )
        resp.raise_for_status()
        return "".join(block.get("text", "") for block in resp.json()["content"])


PROVIDERS: dict[str, type[LLMProvider]] = {
    "mock": MockLLM,
    "openai": OpenAI,
    "openrouter": OpenRouter,
    "anthropic": Anthropic,
    "ollama": Ollama,
    "custom": CustomLLM,
}


def get_llm(db=None) -> LLMProvider:
    """db -> Anbieter/Modell aus der settings-Tabelle (UI), sonst .env."""
    provider = settings.llm_provider
    model: str | None = None
    if db is not None:
        from app.services import settings_svc
        provider = settings_svc.llm_provider(db)
        model = settings_svc.llm_model(db)

    cls = PROVIDERS.get(provider)
    if cls is None:
        log.warning("Unbekannter LLM-Provider '%s' – nutze Mock", provider)
        return MockLLM()
    try:
        return cls(model) if provider != "mock" else cls()
    except RuntimeError as exc:
        # Secret fehlt -> Mock statt harten Pipeline-Abbruch
        log.warning("LLM '%s' nicht konfiguriert (%s) – nutze Mock", provider, exc)
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
