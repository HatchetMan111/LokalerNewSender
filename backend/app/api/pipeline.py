from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import AIJob, City, Episode
from app.workers.pipeline import task_import_news, task_run_pipeline

router = APIRouter(prefix="/api/pipeline", tags=["pipeline"])


@router.post("/import")
def trigger_import(db: Session = Depends(get_db)):
    task = task_import_news.delay()
    return {"queued": True, "task_id": task.id}


@router.post("/generate/{episode_id}")
def trigger_pipeline(episode_id: int, db: Session = Depends(get_db)):
    episode = db.get(Episode, episode_id)
    if not episode:
        raise HTTPException(404, "Sendung nicht gefunden")
    task_run_pipeline.delay(episode_id)
    return {"queued": True, "episode_id": episode_id}


@router.get("/status/{episode_id}")
def pipeline_status(episode_id: int, db: Session = Depends(get_db)):
    episode = db.get(Episode, episode_id)
    if not episode:
        raise HTTPException(404, "Sendung nicht gefunden")
    jobs = (
        db.query(AIJob)
        .filter(AIJob.episode_id == episode_id)
        .order_by(AIJob.id.desc())
        .limit(20)
        .all()
    )
    return {
        "status": episode.status,
        "error": episode.error,
        "jobs": [
            {
                "type": j.type, "provider": j.provider, "model": j.model,
                "status": j.status, "error": j.error,
            }
            for j in jobs
        ],
    }
