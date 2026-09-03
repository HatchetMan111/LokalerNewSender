-- ============================================================
-- Einstellungen (runtime-änderbar über die UI, Key-Value)
-- Worker/Backend lesen diese Werte; Fallback = .env-Defaults.
-- Secrets (API-Keys) bleiben ausschließlich in .env!
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
  -- KI / Texterstellung
  ('llm_provider', 'mock', 'ai', 'KI-Anbieter (LLM)',
   'mock = ohne API-Key | openai | openrouter | anthropic | ollama (lokal) | custom (OpenAI-kompatibel). API-Keys gehören in die .env.'),
  ('llm_model', '', 'ai', 'KI-Modell',
   'Leer = Anbieter-Standard. openai: gpt-4o-mini · openrouter: openai/gpt-4o-mini, anthropic/claude-3.5-sonnet · ollama: llama3.1'),
  -- Sprecher & Audio
  ('tts_provider', 'edge', 'tts', 'Sprachausgabe-Anbieter',
   'edge = kostenlos (Standard) | openai = OpenAI Speech | localai = eigener OpenAI-kompatibler Endpunkt'),
  ('tts_voice', 'de-DE-KatjaNeural', 'tts', 'Sprecher-Stimme',
   'edge: de-DE-KatjaNeural/ConradNeural/… · openai: alloy, echo, nova, onyx, shimmer'),
  ('tts_model', 'tts-1', 'tts', 'TTS-Modell', 'Nur für openai/localai: z.B. tts-1 oder tts-1-hd'),
  ('tts_base_url', '', 'tts', 'TTS-Endpunkt (LocalAI)', 'z.B. http://192.168.178.50:8080/v1 – leer = offizielle OpenAI-API'),
  -- Video-Produktion
  ('renderer_backend', 'ffmpeg', 'video', 'Video-Renderer',
   'ffmpeg = lokal in der VM (Standard) | webhook = externer Render-Service erhält das Production JSON'),
  ('renderer_webhook_url', '', 'video', 'Renderer-Webhook',
   'Nur für webhook-Backend: URL, die per POST das Production JSON empfängt und MP4/MP3 (base64) zurückgibt'),
  ('video_style', 'news-dark', 'video', 'Video-Stil',
   'news-dark (dunkel/blau) | news-light (hell) | minimal (schwarz)'),
  ('video_resolution', '1920x1080', 'video', 'Auflösung',
   '16:9: 1920x1080, 1280x720, 3840x2160 · Vertikal 9:16 (Shorts/Reels): 1080x1920, 720x1280'),
  -- Automatik & Sendung
  ('import_interval_minutes', '60', 'scheduler', 'RSS-Import-Intervall', 'Alle X Minuten importiert der Scheduler neue Nachrichten'),
  ('target_duration', '600', 'episode', 'Standard-Sendungslänge', 'Sekunden; 600 = 10 Minuten')
ON CONFLICT (key) DO NOTHING;
