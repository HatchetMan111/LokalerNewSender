from datetime import date as _date
from typing import Any, Optional

from pydantic import BaseModel


class CityOut(BaseModel):
    id: int
    name: str
    state: Optional[str] = None
    radius_km: int

    class Config:
        from_attributes = True


class EpisodeCreate(BaseModel):
    city_id: int
    date: Optional[_date] = None
    format: str = "daily_news"
    duration: int = 600


class EpisodeOut(BaseModel):
    id: int
    city_id: Optional[int] = None
    date: _date
    title: Optional[str] = None
    format: str
    target_duration: int
    status: str
    script: Optional[dict[str, Any]] = None
    audio_file: Optional[str] = None
    video_file: Optional[str] = None
    error: Optional[str] = None

    class Config:
        from_attributes = True


class EpisodeItemOut(BaseModel):
    id: int
    position: int
    seg_type: str
    duration: int
    headline: Optional[str] = None
    script: Optional[str] = None
    voice_file: Optional[str] = None
    video_file: Optional[str] = None
    status: str

    class Config:
        from_attributes = True


class ArticleOut(BaseModel):
    id: int
    title: str
    url: Optional[str] = None
    location: Optional[str] = None
    category: Optional[str] = None
    importance_score: int
    ai_summary: Optional[str] = None
    status: str

    class Config:
        from_attributes = True


class ScriptUpdate(BaseModel):
    headline: Optional[str] = None
    script: Optional[str] = None
