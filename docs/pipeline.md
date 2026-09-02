# Pipeline

Ein Pipeline-Lauf = Celery-Task `task_run_pipeline(episode_id)`.
Der Worker führt alle Schritte sequenziell aus und aktualisiert nach jedem
Schritt `episodes.status` – die Oberfläche pollt `GET /api/episodes/{id}`
und zeigt den Fortschritt live an.

## Schritte

| # | Schritt | Status danach | Dienst |
|---|---|---|---|
| 1 | News importieren (RSS, Duplikate überspringen) | `collecting` | feedparser |
| 2 | Analysieren: Lokalität + Wichtigkeit (Keywords / LLM) | `collecting` | ai.py |
| 3 | Auswahl + Sendeplan (Intro, 4–8 News, Wetter, Outro) | `selected` | build_schedule() |
| 4 | Sprechertexte (LLM oder Mock-Templates) | `script_ready` | ai.py |
| 5 | TTS pro Segment | `voice_ready` | edge-tts |
| 6 | Video-Render: Titelkarte + Voice → concat → MP4 | `rendered` | FFmpeg |
| 7 | Audio-Export: MP3 | `rendered` | FFmpeg |
| 8 | Production JSON nach /data/exports | `rendered` | – |
| 9 | Freigabe durch Redakteur | `published` | UI / API |

Bei jedem Fehler: `episodes.status = failed`, `episodes.error` gesetzt,
Eintrag in `ai_jobs` – die Sendung kann per `POST /generate` erneut
angestoßen werden (RETRY).

## Sendeplan-Logik (`build_schedule`)

- Intro: 20 s, Outro: 30 s, Wetter: 45 s
- Restzeit gleichmäßig auf 4–8 News verteilen (min. 45 s pro Meldung)
- News sortiert nach `importance_score` (0–100)

## Rendering (FFmpeg als „virtueller Schnittplatz")

Eingabe ist nicht Rohmaterial, sondern das **Production JSON**:
Segmente mit Sprechaudio, Headline, Lower Third, Timing.

- Pro Segment: Full-HD-Titelkarte (drawbox/drawtext) + Voice-Audio → MP4
- Concat aller Segmente → `<stadt>-<datum>.mp4`
- Concat aller Voice-Dateien → `<stadt>-<datum>.mp3`
- Production JSON → `<stadt>-<datum>.json`

Später: echte Bildassets, Intro/Outro-Videos, Musik, Transitions, Templates
(`renderer/templates/`) – das JSON-Schema bleibt identisch.
