"""Pipeline-Worker.

Ein Job = eine Episode. Der Worker arbeitet alle Schritte sequenziell ab:

    import -> analyze -> select -> script -> voice -> render -> review

Jeder Schritt aktualisiert den Episoden-Status, sodass die Oberfläche den
Fortschritt live anzeigen kann. Bei Fehlern: status=FAILED + error-Text.
"""
from __future__ import annotations

import json
import logging
from datetime import date, datetime, timezone

from sqlalchemy.orm import Session

from app.database import SessionLocal
from app.models import AIJob, Article, City, Episode, EpisodeItem
from app.services import importer as importer_svc
from app.services.ai import get_llm
from app.services.renderer import render_episode
from app.services.storage import export_paths, slugify, voice_path
from app.services.tts import get_tts
from app.workers.celery_app import celery_app

log = logging.getLogger(__name__)

STATUSES = [
    "draft", "collecting", "selected", "scripting", "script_ready",
    "voice_generating", "voice_ready", "rendering", "rendered",
    "review", "approved", "published", "failed",
]


def _record_job(db: Session, type_: str, episode_id: int | None, provider: str,
                model: str, input_data: dict, output_data: dict | None,
                error: str | None = None, started: datetime | None = None) -> None:
    db.add(AIJob(
        type=type_, provider=provider, model=model, episode_id=episode_id,
        input_data=input_data, output_data=output_data,
        status="failed" if error else "done", error=error,
        started_at=started or datetime.now(timezone.utc),
        finished_at=datetime.now(timezone.utc),
    ))


def _set_status(db: Session, episode: Episode, status: str) -> None:
    episode.status = status
    episode.updated_at = datetime.now(timezone.utc)
    db.commit()


@celery_app.task(name="app.workers.pipeline.task_import_news")
def task_import_news() -> dict:
    """Scheduler-Job: News aller Städte importieren + analysieren."""
    db = SessionLocal()
    try:
        total = 0
        for city in db.query(City).filter(City.active.is_(True)).all():
            total += importer_svc.import_from_sources(db, city)
            total += importer_svc.analyze_articles(db, city)
        return {"imported": total}
    finally:
        db.close()


@celery_app.task(name="app.workers.pipeline.task_run_pipeline")
def task_run_pipeline(episode_id: int) -> dict:
    db = SessionLocal()
    try:
        episode = db.get(Episode, episode_id)
        if not episode:
            raise RuntimeError(f"Episode {episode_id} nicht gefunden")
        city = db.get(City, episode.city_id)
        from app.services import settings_svc
        episode.voice_id = episode.voice_id or settings_svc.tts_voice(db)
        slug = slugify(f"{city.name}-{episode.date}" if city else f"episode-{episode.id}")

        try:
            # ---------- 1. IMPORT ----------
            _set_status(db, episode, "collecting")
            importer_svc.import_from_sources(db, city)
            importer_svc.analyze_articles(db, city)

            # ---------- 2. AUSWAHL ----------
            articles = (
                db.query(Article)
                .filter(Article.city_id == city.id, Article.status == "ai_processed")
                .order_by(Article.importance_score.desc())
                .all()
            )
            if not articles:
                raise RuntimeError("Keine lokalen Nachrichten gefunden – Quellen prüfen")

            # Sendeplan: Intro + 6-8 News + Wetter + Outro auf Zieldauer verteilen
            plan = build_schedule(articles, episode.target_duration)
            db.query(EpisodeItem).filter(EpisodeItem.episode_id == episode.id).delete()
            items = []
            for pos, seg in enumerate(plan):
                item = EpisodeItem(
                    episode_id=episode.id,
                    article_id=seg.get("article_id"),
                    position=pos,
                    seg_type=seg["type"],
                    duration=seg["duration"],
                    headline=seg.get("headline", ""),
                    status="pending",
                )
                db.add(item)
                items.append(item)
            db.commit()
            _set_status(db, episode, "selected")

            # ---------- 3. SCRIPT ----------
            _set_status(db, episode, "scripting")
            llm = get_llm(db)
            for item in items:
                if item.seg_type == "intro":
                    item.script = (
                        f"Guten Abend und herzlich willkommen zu den Lokalnachrichten "
                        f"für {city.name} und Umgebung. Dies sind die Nachrichten "
                        f"vom {episode.date.strftime('%d.%m.%Y')}."
                    )
                    item.headline = "Lokalnachrichten"
                    item.lower_third = {"title": "LOCAL NEWS", "location": city.name}
                elif item.seg_type == "weather":
                    item.script = (
                        f"Wetter für {city.name}: Heute wechselnd bewölkt bei "
                        f"Temperaturen zwischen 12 und 19 Grad. Am Wochenende "
                        f"wird es freundlicher. Bleiben Sie wetterfest!"
                    )
                    item.headline = "Wetter"
                    item.lower_third = {"title": "WETTER", "location": city.name}
                elif item.seg_type == "outro":
                    item.script = (
                        "Das waren die Lokalnachrichten für heute. "
                        "Vielen Dank für Ihr Interesse – bis morgen Abend!"
                    )
                    item.headline = "Bis morgen"
                    item.lower_third = {"title": "LOCAL NEWS", "location": city.name}
                else:
                    art = db.get(Article, item.article_id)
                    prompt = json.dumps({
                        "headline": art.title,
                        "summary": art.ai_summary or (art.original_text or "")[:800],
                        "city": city.name,
                        "location": art.location or city.name,
                        "max_sentences": 6,
                    }, ensure_ascii=False)
                    try:
                        raw = llm.generate(prompt, system=(
                            "Du bist Radio-Redakteur. Schreibe einen kurzen, sachlichen "
                            "Sprechertext (3-5 Sätze, Deutsch, zum Vorlesen). Nur der Text."
                        ))
                        item.script = raw.strip().strip('"')
                    except Exception as exc:  # noqa: BLE001
                        log.warning("LLM-Script fehlgeschlagen: %s", exc)
                        item.script = f"{art.title}. {art.ai_summary or ''}"
                    item.headline = (art.title[:80]) if art else item.headline
                    item.lower_third = {
                        "title": item.headline,
                        "location": (art.location if art and art.location else city.name),
                    }
                    _record_job(db, "script", episode.id, llm.name,
                                getattr(llm, "model", "mock"), {"prompt": prompt}, {"text": item.script})
                item.status = "script_ready"
                db.commit()
            _set_status(db, episode, "script_ready")

            # ---------- 4. VOICE (TTS) ----------
            _set_status(db, episode, "voice_generating")
            tts = get_tts(db)
            for item in items:
                vp = voice_path(episode.id, item.id)
                tts.synthesize(item.script, vp, voice=episode.voice_id)
                item.voice_file = vp
                item.status = "voice_ready"
                db.commit()
            _set_status(db, episode, "voice_ready")

            # ---------- 5. RENDER (FFmpeg oder Webhook-Renderer) ----------
            _set_status(db, episode, "rendering")
            result = render_episode(
                episode, sorted(items, key=lambda i: i.position),
                backend=settings_svc.renderer_backend(db),
                style=settings_svc.video_style(db),
                resolution=settings_svc.video_resolution(db),
                webhook_url=settings_svc.renderer_webhook_url(db),
            )
            for item in items:
                item.status = "rendered"
            episode.video_file = result["video"]
            episode.audio_file = result["audio"]
            episode.script = result["production"]  # Production JSON als Dict (JSONB)
            _set_status(db, episode, "rendered")
            _set_status(db, episode, "review")

            return {"episode_id": episode.id, "status": "review",
                    "video": result["video"], "audio": result["audio"]}

        except Exception as exc:  # noqa: BLE001
            db.rollback()
            episode = db.get(Episode, episode_id)
            episode.status = "failed"
            episode.error = str(exc)[:2000]
            db.commit()
            _record_job(db, "pipeline", episode_id, "worker", "pipeline",
                        {"episode_id": episode_id}, None, error=str(exc))
            raise
    finally:
        db.close()


def build_schedule(articles: list[Article], target_duration: int) -> list[dict]:
    """Erzeugt den Sendeplan: Intro + News nach Wichtigkeit + Wetter + Outro."""
    plan: list[dict] = [{"type": "intro", "duration": 20}]
    remaining = target_duration - 20 - 45 - 30  # minus intro/wetter/outro
    per_news = max(45, remaining // 6)
    n_news = max(4, min(8, remaining // per_news))
    for art in articles[:n_news]:
        plan.append({"type": "news", "article_id": art.id, "duration": per_news})
    plan.append({"type": "weather", "duration": 45})
    plan.append({"type": "outro", "duration": 30})
    return plan
