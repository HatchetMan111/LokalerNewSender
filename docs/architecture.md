# Architektur

## Grundprinzip: Single-VM-first

Eine Proxmox-VM enthält den kompletten Produktionsstack. Externe APIs liefern
nur KI-Leistung (LLM, TTS). Dadurch bleiben Entwicklung und Administration
überschaubar; einzelne Container können später auf weitere VMs umziehen,
ohne die Architektur zu ändern.

## Container (8 Services)

| Service | Image | Aufgabe |
|---|---|---|
| `frontend` | nginx:alpine | Statische Newsroom-UI + Reverse Proxy + Export-Dateien |
| `backend` | python:3.12-slim | FastAPI: REST-API, Workflow-Endpunkte |
| `worker` | dito | Celery-Worker: Pipeline-Jobs (Script, TTS, FFmpeg) |
| `scheduler` | dito | Celery Beat: periodischer RSS-Import |
| `postgres` | postgres:16 | Datenbank (Herzstück) |
| `redis` | redis:7 | Job-Queue + Result-Backend |

## Datenfluss

```
RSS-Quellen ──▶ Import ──▶ PostgreSQL (articles)
                              │
                    Analyse: Lokalität + Wichtigkeit
                              │
Sendung anlegen (UI) ──▶ Episode + Sendeplan (episode_items)
                              │
        Script (LLM/Mock) ──▶ TTS (edge-tts) ──▶ FFmpeg-Render
                              │
                    /data/exports/*.mp4|mp3|json
                              │
                    Review → Freigabe (Redakteur)
```

## KI-Abstraktionsschicht

`app/services/ai.py` stellt `LLMProvider` bereit (Adapter-Pattern).
Die Pipeline ruft nur `generate()` auf – Provider (Mock, OpenAI, später
Anthropic/lokal) sind austauschbar per `.env`, ohne Pipeline-Code zu ändern.
Gleiches gilt für `tts.py`.

## Was läuft wo

**Lokal (in der VM):** DB, Artikel, Workflow, API, Queue, FFmpeg, Rendering,
Templates, Archiv.
**Extern:** LLM, TTS (MVP: edge-tts), optional Bild-/Video-KI.

## Sicherheit

Vier Stufen: `RAW → AI PROCESSED → EDITOR APPROVED → PUBLISHED`.
Automatische Veröffentlichung durch KI ist im MVP ausgeschlossen;
die Freigabe erfolgt explizit über die Oberfläche.
