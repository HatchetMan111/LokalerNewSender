"""Scheduler ohne Celery Beat.

Liest das Import-Intervall bei JEDEM Durchlauf aus der settings-Tabelle,
sodass Änderungen in der Weboberfläche sofort (ohne Neustart) wirken.
"""
from __future__ import annotations

import logging
import time

from app.database import SessionLocal
from app.services import settings_svc
from app.workers.pipeline import task_import_news

log = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


def current_interval_minutes() -> int:
    try:
        db = SessionLocal()
        try:
            return max(5, settings_svc.import_interval_minutes(db))
        finally:
            db.close()
    except Exception as exc:  # noqa: BLE001
        log.warning("Intervall nicht lesbar (%s) – nutze 60 Min.", exc)
        return 60


def main() -> None:
    log.info("Scheduler gestartet – Intervall kommt live aus der DB.")
    while True:
        minutes = current_interval_minutes()
        try:
            task_import_news.delay()
            log.info("Import-Job angestoßen (nächster in %d Min.)", minutes)
        except Exception as exc:  # noqa: BLE001
            log.warning("Import-Job fehlgeschlagen: %s", exc)
        time.sleep(max(60, minutes * 60))


if __name__ == "__main__":
    main()
