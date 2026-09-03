from datetime import date

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import City, Episode, EpisodeItem
from app.schemas import EpisodeCreate, EpisodeItemOut, EpisodeOut, ScriptUpdate
from app.services.storage import slugify
from app.workers.pipeline import task_run_pipeline

router = APIRouter(prefix="/api/episodes", tags=["episodes"])


@router.get("", response_model=list[EpisodeOut])
def list_episodes(db: Session = Depends(get_db)):
    return db.query(Episode).order_by(Episode.created_at.desc()).limit(50).all()


@router.post("", response_model=EpisodeOut, status_code=201)
def create_episode(payload: EpisodeCreate, db: Session = Depends(get_db)):
    city = db.get(City, payload.city_id)
    if not city:
        raise HTTPException(404, "Stadt nicht gefunden")
    ep_date = payload.date or date.today()
    existing = (
        db.query(Episode)
        .filter(Episode.city_id == city.id, Episode.date == ep_date, Episode.format == payload.format)
        .first()
    )
    if existing:
        return existing
    episode = Episode(
        city_id=city.id,
        date=ep_date,
        title=f"Lokalnachrichten {city.name} – {ep_date.strftime('%d.%m.%Y')}",
        format=payload.format,
        target_duration=payload.duration,
        status="draft",
    )
    db.add(episode)
    db.commit()
    db.refresh(episode)
    return episode


@router.get("/{episode_id}", response_model=EpisodeOut)
def get_episode(episode_id: int, db: Session = Depends(get_db)):
    episode = db.get(Episode, episode_id)
    if not episode:
        raise HTTPException(404, "Sendung nicht gefunden")
    return episode


@router.get("/{episode_id}/items", response_model=list[EpisodeItemOut])
def get_episode_items(episode_id: int, db: Session = Depends(get_db)):
    return (
        db.query(EpisodeItem)
        .filter(EpisodeItem.episode_id == episode_id)
        .order_by(EpisodeItem.position)
        .all()
    )


@router.patch("/{episode_id}/items/{item_id}", response_model=EpisodeItemOut)
def update_item(episode_id: int, item_id: int, payload: ScriptUpdate,
                db: Session = Depends(get_db)):
    """Redakteur kann Sprechertexte ändern, bevor TTS/Render laufen."""
    item = (
        db.query(EpisodeItem)
        .filter(EpisodeItem.episode_id == episode_id, EpisodeItem.id == item_id)
        .first()
    )
    if not item:
        raise HTTPException(404, "Segment nicht gefunden")
    if payload.headline is not None:
        item.headline = payload.headline
    if payload.script is not None:
        item.script = payload.script
    db.commit()
    db.refresh(item)
    return item


@router.post("/{episode_id}/generate")
def generate_episode(episode_id: int, db: Session = Depends(get_db)):
    """Startet Import + Auswahl + Scripts und PAUSIERT bei script_ready.

    Der Redakteur prüft/ändert Sprechertexte in der UI (Sendeplan-Editor),
    danach geht es mit POST /continue (Sprecher -> Video -> Audio) weiter.
    """
    episode = db.get(Episode, episode_id)
    if not episode:
        raise HTTPException(404, "Sendung nicht gefunden")
    if episode.status in ("collecting", "scripting", "voice_generating", "rendering"):
        raise HTTPException(409, f"Pipeline läuft bereits (Status: {episode.status})")
    episode.status = "draft"
    episode.error = None
    db.commit()
    task_run_pipeline.delay(episode_id, upto="script")
    return {"episode_id": episode_id, "queued": True, "upto": "script"}


@router.post("/{episode_id}/continue")
def continue_episode(episode_id: int, db: Session = Depends(get_db)):
    """Setzt nach der Redaktions-Prüfung fort: Sprecher -> Video -> Audio."""
    episode = db.get(Episode, episode_id)
    if not episode:
        raise HTTPException(404, "Sendung nicht gefunden")
    if episode.status not in ("script_ready", "selected"):
        raise HTTPException(409, f"Fortsetzen erst nach Script-Phase möglich (Status: {episode.status})")
    task_run_pipeline.delay(episode_id, start_from="voice", upto="review")
    return {"episode_id": episode_id, "queued": True, "from": "voice"}


@router.post("/{episode_id}/approve")
def approve_episode(episode_id: int, db: Session = Depends(get_db)):
    episode = db.get(Episode, episode_id)
    if not episode:
        raise HTTPException(404, "Sendung nicht gefunden")
    if episode.status not in ("rendered", "review"):
        raise HTTPException(409, f"Freigabe erst nach Render möglich (Status: {episode.status})")
    episode.status = "published"
    db.commit()
    return {"episode_id": episode_id, "status": "published"}


@router.get("/{episode_id}/download")
def download_links(episode_id: int, db: Session = Depends(get_db)):
    episode = db.get(Episode, episode_id)
    if not episode:
        raise HTTPException(404, "Sendung nicht gefunden")
    city = db.get(City, episode.city_id)
    slug = slugify(f"{city.name}-{episode.date}" if city else f"episode-{episode.id}")
    return {
        "video": f"/media/exports/{slug}/{slug}.mp4",
        "audio": f"/media/exports/{slug}/{slug}.mp3",
        "json": f"/media/exports/{slug}/{slug}.json",
    }
