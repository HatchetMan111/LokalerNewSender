from celery import Celery

from app.config import settings

celery_app = Celery(
    "localnews",
    broker=settings.redis_url,
    backend=settings.redis_url,
)

celery_app.conf.timezone = "Europe/Berlin"

# Hinweis: Der periodische Import läuft NICHT über Celery Beat, sondern über
# app.workers.scheduler (eigener Loop), damit das Intervall live aus der
# settings-Tabelle gelesen wird (UI-Einstellung ohne Neustart wirksam).

import app.workers.pipeline  # noqa: E402,F401  (Tasks registrieren)
