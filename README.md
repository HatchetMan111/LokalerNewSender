# Local News Platform

**Eine VM. Ein Repository. Ein Docker-Compose-Stack. Eine Oberfläche.**

Die Plattform verwandelt lokale Nachrichtenquellen (RSS) in eine fertige,
gesprochene Nachrichtensendung (MP4 + MP3) – vollständig automatisch:

```
Datenbank → redaktionelle Logik → KI → Medienproduktion → Qualitätskontrolle
```

## Architektur (Single-VM-first)

```
                 INTERNET / APIs (LLM, TTS, RSS)
                            │
┌───────────────────────────┼──────────────────────────────┐
│  PROXMOX VM „local-news"  │                              │
│                           ▼                              │
│  ┌──────────────── Docker Compose ────────────────────┐  │
│  │  nginx ──── Frontend (Newsroom-UI)                 │  │
│  │     └────── FastAPI Backend (/api)                 │  │
│  │                ├── PostgreSQL (Daten, Sendungen)   │  │
│  │                ├── Redis (Job Queue)               │  │
│  │                ├── Celery Worker (Pipeline)        │  │
│  │                ├── Celery Beat (Scheduler/Import)  │  │
│  │                └── FFmpeg Renderer (MP4/MP3)       │  │
│  └────────────────────────────────────────────────────┘  │
│                      /data (media, projects, exports)    │
└──────────────────────────────────────────────────────────┘
```

Alle Daten (Artikel, Scripts, Sendepläne, Produktionen) bleiben lokal.
Nur die rechenintensive KI (LLM, TTS) läuft extern bzw. als MVP über
kostenlose Dienste.

## Installation

### 1. Proxmox-VM erstellen (auf dem Proxmox-Host)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LokalerNewSender/main/proxmox/local-news-vm.sh)"
```

Das Script fragt **interaktiv** ab (whiptail-Dialoge): VM-ID, vCPUs, RAM,
Disk-Größe, Storage und Bridge — so kannst du für Tests eine kleine VM
wählen (Default: 2 vCPU / 4 GB / 32 GB) und für Produktion mehr
(empfohlen: 8 vCPU / 16 GB / 64 GB+).

Ohne Nachfragen (z.B. für Automation) — Werte per ENV setzen:

```bash
INTERACTIVE=no VMID=9100 CORES=4 RAM=8192 DISK_SIZE=64G \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/LokalerNewSender/main/proxmox/local-news-vm.sh)"
```

Weitere ENV-Override-Parameter: `VM_NAME`, `STORAGE`, `BRIDGE`, `VLAN`,
`SSH_USER`, `SSH_PASSWORD`, `SSH_KEY` (Pfad zu Public-Key-Datei),
`REPO_URL`, `REPO_BRANCH`, `START_VM=yes|no`.

Das Script:
- lädt das Debian-12-Cloud-Image
- erstellt die VM in der von dir gewählten Größe
- konfiguriert Cloud-Init (Installer läuft beim ersten Boot automatisch)
- installiert Docker + deployt den kompletten Stack

> **Hinweis für kleine Test-VMs:** Mit 2 vCPU / 4 GB dauert der erste
> Docker-Build mehrere Minuten; die Pipeline (besonders FFmpeg-Render)
> läuft langsamer. Das reicht für MVP-Tests voll aus.

Fortschritt in der VM beobachten:

```bash
qm terminal <VMID>        # oder in der VM:
tail -f /var/log/local-news-install.log
```

### 2. Manuell (bereits vorhandene VM / beliebiges Linux)

```bash
git clone https://github.com/HatchetMan111/LokalerNewSender.git
cd local-news-platform
cp .env.example .env          # Passwörter/Keys anpassen
docker compose up -d --build
```

### 3. Oberfläche öffnen

```
http://<VM-IP>          → LOCAL NEWSROOM Dashboard
http://<VM-IP>/api/docs → FastAPI (Swagger)
```

## MVP-Workflow (Oberfläche)

1. **Sendung erstellen** – Stadt, Datum, Format, Länge wählen → `SENDUNG GENERIEREN`
2. Pipeline läuft automatisch:
   `Import → Analyse (Prio) → Auswahl → Script → Voice (TTS) → Video (FFmpeg) → Audio → Review`
3. Status-Checkliste live auf dem Dashboard
4. `VIDEO ANSEHEN` / `AUDIO ANHÖREN` / `FREIGEBEN`

## API

```
GET  /api/cities                          Städte
GET  /api/articles?city_id=1              Artikel (nach Prio)
POST /api/episodes                        Sendung anlegen (idempotent pro Tag/Format)
GET  /api/episodes/{id}                   Status
GET  /api/episodes/{id}/items             Sendeplan
PATCH /api/episodes/{id}/items/{item_id}  Script durch Redakteur ändern
POST /api/episodes/{id}/generate          Pipeline starten
POST /api/episodes/{id}/approve           Freigabe → published
GET  /api/episodes/{id}/download          Links auf MP4/MP3/JSON
POST /api/pipeline/import                 RSS-Import manuell anstoßen
GET  /api/pipeline/status/{id}            Job-Audit (welches Modell, Fehler ...)
```

## Konfiguration (`.env`)

| Variable | Default | Bedeutung |
|---|---|---|
| `LLM_PROVIDER` | `mock` | `mock` (ohne API-Key lauffähig) oder `openai` |
| `OPENAI_API_KEY` | – | für echtes LLM (Scripts/Analyse) |
| `TTS_PROVIDER` | `edge` | MVP: edge-tts (kostenlose deutsche Stimmen) |
| `TTS_VOICE` | `de-DE-KatjaNeural` | z.B. `de-DE-ConradNeural` (männlich) |
| `IMPORT_INTERVAL_MINUTES` | `60` | Scheduler-Import |
| `HTTP_PORT` | `80` | Web-Port |

Der Mock-LLM-Provider erzeugt template-basierte deutsche Sprechertexte –
so läuft die komplette Pipeline **ohne** API-Key und kann später per
`.env` auf echte Modelle umgestellt werden (keine Code-Änderung nötig,
 dank AI-Abstraktionsschicht).

## Output

```
/data/exports/<stadt>-<datum>/
  ├── <stadt>-<datum>.mp4     fertige Sendung
  ├── <stadt>-<datum>.mp3     Audio-Fassung
  └── <stadt>-<datum>.json    Production JSON (Sendeplan, Scripts, Timing)
```

## Repository-Struktur

```
local-news-platform/
├── proxmox/local-news-vm.sh   # Proxmox-VM-Installer (Community-Scripts-Stil)
├── docker-compose.yml
├── .env.example
├── db/init.sql                # PostgreSQL-Schema + Seed
├── backend/                   # FastAPI + Celery + Renderer
│   └── app/{api,models,schemas,services,workers}
├── frontend/                  # Newsroom-UI (HTML/JS, nginx)
├── nginx/nginx.conf
└── docs/                      # architecture, database, pipeline
```

## Sicherheitsmodell

```
RAW → AI PROCESSED → EDITOR APPROVED → PUBLISHED
```

KI darf zusammenfassen und vorschlagen – veröffentlichen wird nur der
Redakteur (Freigabe-Button / `/approve`).

## Roadmap nach MVP-01

- News-Auswahl-UI (manuell pro Artikel wählen statt nur Auto-Prio)
- Echte Bildassets zu Artikeln (Media-Assets-Tabelle ist vorbereitet)
- Template-System (Intro/Outro-Videos, Musik, Lower-Third-Grafiken)
- Weitere AI-Provider (Anthropic, lokale Modelle) via Adapter
- GPU-Passthrough für lokale TTS/LLM
