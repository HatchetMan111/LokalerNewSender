-- ============================================================
-- Einstellungen (runtime-änderbar über die UI, Key-Value)
-- Worker/Backend lesen diese Werte; Fallback = .env-Defaults.
-- ============================================================
CREATE TABLE IF NOT EXISTS settings (
    key         VARCHAR(80) PRIMARY KEY,
    value       TEXT NOT NULL,
    category    VARCHAR(40) DEFAULT 'general',
    label       VARCHAR(200),
    description VARCHAR(500),
    updated_at  TIMESTAMPTZ DEFAULT now()
);

INSERT INTO settings (key, value, category, label, description) VALUES
  ('llm_provider',   'mock',   'ai',    'KI-Anbieter (LLM)',      'mock = ohne API-Key lauffähig; openai = echte Sprechertexte (OPENAI_API_KEY in .env nötig)'),
  ('openai_model',   'gpt-4o-mini', 'ai', 'OpenAI-Modell',       'Modell für Script/Analyse, z.B. gpt-4o-mini oder gpt-4o'),
  ('tts_provider',   'edge',   'tts',   'Sprachausgabe-Anbieter', 'edge = kostenlose Microsoft-Stimmen (Standard)'),
  ('tts_voice',      'de-DE-KatjaNeural', 'tts', 'Sprecher-Stimme', 'de-DE-KatjaNeural (w), de-DE-ConradNeural (m), de-DE-AmalaNeural (w), de-DE-KatjaNeural, de-DE-BerndNeural (m), de-DE-ElkeNeural (w)'),
  ('import_interval_minutes', '60', 'scheduler', 'RSS-Import-Intervall', 'Alle X Minuten importiert der Scheduler neue Nachrichten (Neustart der Worker aktiviert es)'),
  ('target_duration', '600',   'episode', 'Standard-Sendungslänge', 'Sekunden; 600 = 10 Minuten')
ON CONFLICT (key) DO NOTHING;
