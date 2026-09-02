-- ============================================================
-- local-news-platform · PostgreSQL Schema (init)
-- Wird beim ersten Start des postgres-Containers ausgeführt.
-- ============================================================

CREATE TABLE IF NOT EXISTS cities (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(120) NOT NULL UNIQUE,
    state       VARCHAR(120),
    country     VARCHAR(8) DEFAULT 'DE',
    latitude    DOUBLE PRECISION,
    longitude   DOUBLE PRECISION,
    radius_km   INT DEFAULT 25,
    active      BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS sources (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(160) NOT NULL,
    url         VARCHAR(500),
    type        VARCHAR(40) DEFAULT 'rss',          -- rss | manual | api
    rss_url     VARCHAR(500),
    trust_score INT DEFAULT 50,                     -- 0..100
    active      BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS articles (
    id              SERIAL PRIMARY KEY,
    source_id       INT REFERENCES sources(id),
    title           VARCHAR(500) NOT NULL,
    original_text   TEXT,
    url             VARCHAR(700),
    published_at    TIMESTAMPTZ,
    event_date      DATE,
    location        VARCHAR(200),
    city_id         INT REFERENCES cities(id),
    category        VARCHAR(60),
    importance_score INT DEFAULT 0,                  -- 0..100 (KI/Heuristik)
    ai_summary      TEXT,
    ai_facts        JSONB,
    ai_topics       JSONB,
    status          VARCHAR(30) DEFAULT 'raw',       -- raw | ai_processed | editor_approved | published
    duplicate_of_id INT REFERENCES articles(id),
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_articles_city_status ON articles(city_id, status);
CREATE INDEX IF NOT EXISTS idx_articles_published ON articles(published_at DESC);

CREATE TABLE IF NOT EXISTS media_assets (
    id               SERIAL PRIMARY KEY,
    article_id       INT REFERENCES articles(id),
    type             VARCHAR(30) NOT NULL,           -- image | video | audio | generated
    file_path        VARCHAR(500),
    original_url     VARCHAR(700),
    mime_type        VARCHAR(120),
    width            INT,
    height           INT,
    duration         DOUBLE PRECISION,
    copyright_status VARCHAR(40) DEFAULT 'unknown',
    license          VARCHAR(160),
    ai_generated     BOOLEAN DEFAULT FALSE,
    created_at       TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Sendungen
-- ============================================================
CREATE TABLE IF NOT EXISTS episodes (
    id              SERIAL PRIMARY KEY,
    city_id         INT REFERENCES cities(id),
    date            DATE NOT NULL,
    title           VARCHAR(240),
    format          VARCHAR(60) DEFAULT 'daily_news',
    target_duration INT DEFAULT 600,                 -- Sekunden
    status          VARCHAR(40) DEFAULT 'draft',     -- siehe Workflow-Zustände
    intro_asset     INT,
    outro_asset     INT,
    voice_id        VARCHAR(120),
    script          JSONB,                           -- Production JSON
    audio_file      VARCHAR(500),
    video_file      VARCHAR(500),
    error           TEXT,
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now(),
    UNIQUE (city_id, date, format)
);

CREATE TABLE IF NOT EXISTS episode_items (
    id          SERIAL PRIMARY KEY,
    episode_id  INT REFERENCES episodes(id) ON DELETE CASCADE,
    article_id  INT REFERENCES articles(id),
    position    INT NOT NULL,
    seg_type    VARCHAR(30) DEFAULT 'news',          -- intro | news | weather | outro
    duration    INT DEFAULT 60,
    headline    VARCHAR(300),
    script      TEXT,
    lower_third JSONB,
    voice_file  VARCHAR(500),
    video_file  VARCHAR(500),
    status      VARCHAR(30) DEFAULT 'pending',       -- pending | script_ready | voice_ready | rendered | failed
    created_at  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_episode_items ON episode_items(episode_id, position);

-- ============================================================
-- KI-Jobs (Audit: welches Modell, Input, Output, Fehler)
-- ============================================================
CREATE TABLE IF NOT EXISTS ai_jobs (
    id          SERIAL PRIMARY KEY,
    type        VARCHAR(60) NOT NULL,                -- analyze | select | script | tts
    provider    VARCHAR(60),
    model       VARCHAR(120),
    episode_id  INT REFERENCES episodes(id),
    article_id  INT REFERENCES articles(id),
    input_data  JSONB,
    output_data JSONB,
    status      VARCHAR(30) DEFAULT 'pending',       -- pending | running | done | failed
    error       TEXT,
    started_at  TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- Seed: erste Stadt + Quelldaten
-- ============================================================
INSERT INTO cities (name, state, country, latitude, longitude, radius_km, active)
VALUES ('Bad Mergentheim', 'Baden-Württemberg', 'DE', 49.4892, 9.7714, 25, TRUE)
ON CONFLICT (name) DO NOTHING;

INSERT INTO sources (name, url, type, rss_url, trust_score, active) VALUES
  ('Presseportal Polizei',      'https://www.presseportal.de', 'rss', 'https://www.presseportal.de/rss/polizei/40.rss', 85, TRUE),
  ('Presseportal Sonstiges',    'https://www.presseportal.de', 'rss', 'https://www.presseportal.de/rss/40.rss',         75, TRUE),
  ('Stadtverwaltung (manuell)', NULL,                          'manual', NULL,                                          90, FALSE),
  ('Lokale Zeitung (manuell)',  NULL,                          'manual', NULL,                                          80, FALSE)
ON CONFLICT DO NOTHING;
