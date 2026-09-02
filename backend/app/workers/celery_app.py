from celery import Celery

from app.config import settings

celery_app = Celery(
    "localnews",
    broker=settings.redis_url,
    backend=settings.redis_url,
)

celery_app.conf.beat_schedule = {
    "import-news": {
        "task": "app.workers.pipeline.task_import_news",
        "schedule": settings.import_interval_minutes * 60,
    },
}
celery_app.conf.timezone = "Europe/Berlin"

import app.workers.pipeline  # noqa: E402,F401  (Tasks registrieren)
