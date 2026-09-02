from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "postgresql+psycopg2://localnews:localnews@postgres:5432/localnews"
    redis_url: str = "redis://redis:6379/0"

    llm_provider: str = "mock"
    openai_api_key: str = ""
    openai_model: str = "gpt-4o-mini"

    tts_provider: str = "edge"
    tts_voice: str = "de-DE-KatjaNeural"

    video_resolution: str = "1920x1080"
    video_fps: int = 25

    import_interval_minutes: int = 60
    data_dir: str = "/data"

    class Config:
        env_file = ".env"


settings = Settings()
