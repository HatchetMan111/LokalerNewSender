from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "postgresql+psycopg2://localnews:localnews@postgres:5432/localnews"
    redis_url: str = "redis://redis:6379/0"

    # ---- LLM (Default = .env; überschreibbar über die UI/settings-Tabelle) ----
    llm_provider: str = "mock"
    openai_api_key: str = ""
    openai_model: str = "gpt-4o-mini"

    # OpenRouter (https://openrouter.ai)
    openrouter_api_key: str = ""
    openrouter_model: str = "openai/gpt-4o-mini"

    # Anthropic (https://console.anthropic.com)
    anthropic_api_key: str = ""
    anthropic_model: str = "claude-3-5-haiku-latest"

    # Ollama (lokale Instanz, z.B. http://ollama:11434)
    ollama_base_url: str = ""
    ollama_model: str = "llama3.1"

    # Custom: beliebiger OpenAI-kompatibler Endpunkt (LocalAI, vLLM, ...)
    llm_base_url: str = ""
    llm_model: str = ""
    llm_api_key: str = ""

    # ---- TTS ----
    tts_provider: str = "edge"
    tts_voice: str = "de-DE-KatjaNeural"
    tts_model: str = "tts-1"          # für openai/LocalAI-Speech
    tts_base_url: str = ""            # leer = offizielle API; sonst LocalAI etc.

    # ---- Video ----
    video_resolution: str = "1920x1080"
    video_fps: int = 25
    video_style: str = "news-dark"    # news-dark | news-light | minimal
    renderer_backend: str = "ffmpeg"  # ffmpeg | webhook
    renderer_webhook_url: str = ""    # externer Render-Service (Production JSON via POST)

    import_interval_minutes: int = 60
    data_dir: str = "/data"

    class Config:
        env_file = ".env"


settings = Settings()
