from datetime import date, datetime
from typing import Any

from pydantic import BaseModel


class CityOut(BaseModel):
    id: int
    name: str
    state: str | None
    radius_km: int

    class Config:
        from_attributes = True


class EpisodeCreate(BaseModel):
    city_id: int
    date: date | None = None
    format: str = "daily_news"
    duration: int = 600


class EpisodeOut(BaseModel):
    id: int
    city_id: int | None
    date: date
    title: str | None
    format: str
    target_duration: int
    status: str
    script: dict[str, Any] | None
    audio_file: str | None
    video_file: str | None
    error: str | None

    class Config:
        from_attributes = True


class EpisodeItemOut(BaseModel):
    id: int
    position: int
    seg_type: str
    duration: int
    headline: str | None
    script: str | None
    voice_file: str | None
    video_file: str | None
    status: str

    class Config:
        from_attributes = True


class ArticleOut(BaseModel):
    id: int
    title: str
    url: str | None
    location: str | None
    category: str | None
    importance_score: int
    ai_summary: str | None
    status: str

    class Config:
        from_attributes = True


class ScriptUpdate(BaseModel):
    headline: str | None = None
    script: str | None = None


class PipelineStep(BaseModel):
    step: str  # import | analyze | select | script | voice | render | publish
