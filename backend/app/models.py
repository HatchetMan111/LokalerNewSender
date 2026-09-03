from datetime import date, datetime

from sqlalchemy import (
    JSON,
    Boolean,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class City(Base):
    __tablename__ = "cities"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True)
    state: Mapped[str | None] = mapped_column(String(120))
    country: Mapped[str] = mapped_column(String(8), default="DE")
    latitude: Mapped[float | None] = mapped_column(Float)
    longitude: Mapped[float | None] = mapped_column(Float)
    radius_km: Mapped[int] = mapped_column(Integer, default=25)
    active: Mapped[bool] = mapped_column(Boolean, default=True)

    episodes: Mapped[list["Episode"]] = relationship(back_populates="city")


class Source(Base):
    __tablename__ = "sources"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(160))
    url: Mapped[str | None] = mapped_column(String(500))
    type: Mapped[str] = mapped_column(String(40), default="rss")
    rss_url: Mapped[str | None] = mapped_column(String(500))
    trust_score: Mapped[int] = mapped_column(Integer, default=50)
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class Article(Base):
    __tablename__ = "articles"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    source_id: Mapped[int | None] = mapped_column(ForeignKey("sources.id"))
    title: Mapped[str] = mapped_column(String(500))
    original_text: Mapped[str | None] = mapped_column(Text)
    url: Mapped[str | None] = mapped_column(String(700))
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    event_date: Mapped[date | None] = mapped_column(Date)
    location: Mapped[str | None] = mapped_column(String(200))
    city_id: Mapped[int | None] = mapped_column(ForeignKey("cities.id"))
    category: Mapped[str | None] = mapped_column(String(60))
    importance_score: Mapped[int] = mapped_column(Integer, default=0)
    ai_summary: Mapped[str | None] = mapped_column(Text)
    ai_facts: Mapped[dict | None] = mapped_column(JSON)
    ai_topics: Mapped[dict | None] = mapped_column(JSON)
    status: Mapped[str] = mapped_column(String(30), default="raw")
    duplicate_of_id: Mapped[int | None] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)


class MediaAsset(Base):
    __tablename__ = "media_assets"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    article_id: Mapped[int | None] = mapped_column(ForeignKey("articles.id"))
    type: Mapped[str] = mapped_column(String(30))
    file_path: Mapped[str | None] = mapped_column(String(500))
    original_url: Mapped[str | None] = mapped_column(String(700))
    mime_type: Mapped[str | None] = mapped_column(String(120))
    width: Mapped[int | None] = mapped_column(Integer)
    height: Mapped[int | None] = mapped_column(Integer)
    duration: Mapped[float | None] = mapped_column(Float)
    copyright_status: Mapped[str] = mapped_column(String(40), default="unknown")
    license: Mapped[str | None] = mapped_column(String(160))
    ai_generated: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)


class Episode(Base):
    __tablename__ = "episodes"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    city_id: Mapped[int | None] = mapped_column(ForeignKey("cities.id"))
    date: Mapped[date] = mapped_column(Date)
    title: Mapped[str | None] = mapped_column(String(240))
    format: Mapped[str] = mapped_column(String(60), default="daily_news")
    target_duration: Mapped[int] = mapped_column(Integer, default=600)
    status: Mapped[str] = mapped_column(String(40), default="draft")
    intro_asset: Mapped[int | None] = mapped_column(Integer)
    outro_asset: Mapped[int | None] = mapped_column(Integer)
    voice_id: Mapped[str | None] = mapped_column(String(120))
    script: Mapped[dict | None] = mapped_column(JSON)
    audio_file: Mapped[str | None] = mapped_column(String(500))
    video_file: Mapped[str | None] = mapped_column(String(500))
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)

    city: Mapped["City | None"] = relationship(back_populates="episodes", lazy="joined")
    items: Mapped[list["EpisodeItem"]] = relationship(
        back_populates="episode", order_by="EpisodeItem.position", cascade="all, delete-orphan"
    )


class EpisodeItem(Base):
    __tablename__ = "episode_items"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    episode_id: Mapped[int] = mapped_column(ForeignKey("episodes.id", ondelete="CASCADE"))
    article_id: Mapped[int | None] = mapped_column(ForeignKey("articles.id"))
    position: Mapped[int] = mapped_column(Integer)
    seg_type: Mapped[str] = mapped_column(String(30), default="news")
    duration: Mapped[int] = mapped_column(Integer, default=60)
    headline: Mapped[str | None] = mapped_column(String(300))
    script: Mapped[str | None] = mapped_column(Text)
    lower_third: Mapped[dict | None] = mapped_column(JSON)
    voice_file: Mapped[str | None] = mapped_column(String(500))
    video_file: Mapped[str | None] = mapped_column(String(500))
    status: Mapped[str] = mapped_column(String(30), default="pending")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)

    episode: Mapped["Episode"] = relationship(back_populates="items")
    article: Mapped["Article | None"] = relationship(lazy="joined")


class Setting(Base):
    """Runtime-Einstellungen, änderbar über die UI (Key-Value)."""
    __tablename__ = "settings"
    key: Mapped[str] = mapped_column(String(80), primary_key=True)
    value: Mapped[str] = mapped_column(Text)
    category: Mapped[str] = mapped_column(String(40), default="general")
    label: Mapped[str | None] = mapped_column(String(200))
    description: Mapped[str | None] = mapped_column(String(500))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=datetime.utcnow, onupdate=datetime.utcnow
    )


class AIJob(Base):
    __tablename__ = "ai_jobs"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    type: Mapped[str] = mapped_column(String(60))
    provider: Mapped[str | None] = mapped_column(String(60))
    model: Mapped[str | None] = mapped_column(String(120))
    episode_id: Mapped[int | None] = mapped_column(ForeignKey("episodes.id"))
    article_id: Mapped[int | None] = mapped_column(ForeignKey("articles.id"))
    input_data: Mapped[dict | None] = mapped_column(JSON)
    output_data: Mapped[dict | None] = mapped_column(JSON)
    status: Mapped[str] = mapped_column(String(30), default="pending")
    error: Mapped[str | None] = mapped_column(Text)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)


Index("idx_articles_city_status", Article.city_id, Article.status)
Index("idx_episode_items", EpisodeItem.episode_id, EpisodeItem.position)
