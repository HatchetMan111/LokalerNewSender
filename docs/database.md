# Datenbankschema

Kanonisches Schema: `db/init.sql` (wird beim ersten Postgres-Start ausgeführt).
Entsprechende SQLAlchemy-Models: `backend/app/models.py`.

## Tabellen

### cities
`id, name (unique), state, country, latitude, longitude, radius_km, active`

### sources
`id, name, url, type (rss|manual|api), rss_url, trust_score, active`

### articles
`id, source_id, title, original_text, url, published_at, event_date,
location, city_id, category, importance_score, ai_summary, ai_facts (jsonb),
ai_topics (jsonb), status, duplicate_of_id, created_at, updated_at`

Status-Stufen: `raw → ai_processed → editor_approved → published`
(plus `rejected_nonlocal`).

### media_assets
`id, article_id, type (image|video|audio|generated), file_path, original_url,
mime_type, width, height, duration, copyright_status, license, ai_generated`

### episodes
`id, city_id, date, title, format, target_duration, status, intro_asset,
outro_asset, voice_id, script (jsonb = Production JSON), audio_file,
video_file, error, created_at, updated_at`
Unique: `(city_id, date, format)` – pro Tag/Stadt/Format genau eine Ausgabe.

Workflow-Zustände:
```
DRAFT → COLLECTING → SELECTED → SCRIPTING → SCRIPT_READY
→ VOICE_GENERATING → VOICE_READY → RENDERING → RENDERED
→ REVIEW → APPROVED → PUBLISHED        (Fehler: FAILED)
```

### episode_items
`id, episode_id, article_id, position, seg_type (intro|news|weather|outro),
duration, headline, script, lower_third (jsonb), voice_file, video_file, status`

### ai_jobs (Audit)
`id, type (analyze|select|script|tts|pipeline), provider, model, episode_id,
article_id, input_data (jsonb), output_data (jsonb), status, error,
started_at, finished_at`

Damit ist nachvollziehbar: welche KI, welches Modell, wann, mit welchem
Input und Output – Grundlage für Qualitätskontrolle und Regressionstests.

## Seed

- Stadt: **Bad Mergentheim** (Baden-Württemberg, Radius 25 km)
- Quellen: Presseportal (Polizei + Sonstiges, aktiv), Stadtverwaltung /
  lokale Zeitung als manuelle Platzhalter (inaktiv – RSS-URL ergänzen)
