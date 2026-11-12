// Deutsche Labels + Status→Schritt-Mapping für den Produktions-Stepper.

export const STEPS = [
  { key: "collecting",   label: "Nachrichten geladen" },
  { key: "selected",     label: "Auswahl getroffen" },
  { key: "script_ready", label: "Scripts erstellt" },
  { key: "voice_ready",  label: "Sprecher erstellt" },
  { key: "rendering",    label: "Video produziert" },
  { key: "review",       label: "Audio fertig / Freigabe" },
];

export const STATUS_DE = {
  draft: "Entwurf",
  collecting: "Sammelt News",
  selected: "Auswahl steht",
  scripting: "Schreibt Scripts",
  script_ready: "Script bereit zur Prüfung",
  voice_generating: "Erzeugt Sprecher",
  voice_ready: "Sprecher fertig",
  rendering: "Rendert Video",
  rendered: "Gerendert",
  review: "Bereit zur Freigabe",
  approved: "Freigegeben",
  published: "Veröffentlicht",
  failed: "Fehler",
};

export const FORMAT_DE = { daily_news: "Tagesnews", breaking_news: "Breaking News" };
export const SEG_DE = { intro: "Intro", news: "News", weather: "Wetter", outro: "Outro" };
export const ARTICLE_STATUS_DE = {
  raw: "Roh",
  ai_processed: "KI-geprüft",
  editor_approved: "Redaktion-OK",
  published: "Veröffentlicht",
  rejected_nonlocal: "Nicht lokal",
};

export const statusDe = (s) => STATUS_DE[s] || s;

// Pipeline-Status → Index des AKTIVEN Schritts im Stepper.
// Alles davor ist fertig, alles danach pending. "script_ready" ist der
// Redaktions-Checkpunkt (pausiert), "review"+ der Endzustand.
export const RUNNING_STATUS_TO_STEP = {
  draft: 0,
  collecting: 0,
  selected: 2,      // Auswahl fertig, Scripting startet
  scripting: 2,
  script_ready: 3,  // pausiert: Sprecher wartet auf Redaktions-Freigabe
  voice_generating: 3,
  voice_ready: 4,   // Sprecher fertig, Rendern startet
  rendering: 4,
  rendered: 5,      // QC + Audio laufen
  review: 5,
  approved: 6,
  published: 6,
};

export const FINAL_STATUSES = ["review", "approved", "published"];
export const RUNNING_STATUSES = ["collecting", "scripting", "voice_generating", "rendering"];
