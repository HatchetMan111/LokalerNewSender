import React, { useCallback, useEffect, useRef, useState } from "react";
import { get, post, patch } from "../api.js";
import { useToast } from "../toast.jsx";
import {
  STEPS, RUNNING_STATUS_TO_STEP, FINAL_STATUSES,
  FORMAT_DE, SEG_DE, statusDe,
} from "../labels.js";

// Pipeline-Status → Stepper-Zustände. Fix ggü. der Alt-UI: Bei den
// Pause-Status (selected/script_ready/voice_ready) werden NICHT mehr alle
// Schritte als erledigt angezeigt, sondern nur die wirklich fertigen.
function deriveSteps(status) {
  const failed = status === "failed";
  const idx = RUNNING_STATUS_TO_STEP[status] ?? 0;
  const paused = status === "script_ready";
  return STEPS.map((s, i) => {
    let state = "pending";
    if (failed) {
      if (i < idx) state = "done";
      else if (i === idx) state = "failed";
    } else if (FINAL_STATUSES.includes(status) || i < idx) {
      state = "done";
    } else if (i === idx) {
      state = paused ? "waiting" : "active";
    }
    return { ...s, state };
  });
}

const STEP_ICON = { done: "✓", active: "→", waiting: "⏸", failed: "✗", pending: "○" };
const JOBTYPE_DE = { script: "Script", voice: "Sprecher", qc: "Qualitätskontrolle", pipeline: "Pipeline" };

export default function Dashboard({ cities, refreshCities, openEpisodeId, onOpened }) {
  const toast = useToast();

  // Formular
  const [cityId, setCityId] = useState("");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [format, setFormat] = useState("daily_news");
  const [duration, setDuration] = useState(600);
  const [creating, setCreating] = useState(false);

  // Aktuelle Sendung
  const [ep, setEp] = useState(null);
  const [items, setItems] = useState([]);
  const [audit, setAudit] = useState([]);
  const [links, setLinks] = useState(null);
  const [showAudit, setShowAudit] = useState(false);
  const [acting, setActing] = useState(false);

  const pollRef = useRef(null);
  const episodeRef = useRef(null);
  episodeRef.current = ep?.id ?? null;

  const stopPoll = useCallback(() => {
    if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
  }, []);

  const applyStatus = useCallback(async (episode) => {
    setEp(episode);
    const status = episode.status;

    // Terminal = Redaktions-Checkpunkt, Endfreigabe oder Fehler.
    // ALLES andere (auch selected/voice_ready/rendered) läuft weiter –
    // sonst stoppt das Polling mitten in der Pipeline.
    if (![...FINAL_STATUSES, "script_ready", "failed"].includes(status)) return "keep-polling";

    if (status === "script_ready") {
      const [epItems, epAudit] = await Promise.all([
        get(`/api/episodes/${episode.id}/items`),
        get(`/api/pipeline/status/${episode.id}`),
      ]);
      setItems(epItems);
      setAudit(epAudit.jobs || []);
      return "stop";
    }
    if (FINAL_STATUSES.includes(status)) {
      const epAudit = await get(`/api/pipeline/status/${episode.id}`).catch(() => null);
      if (epAudit) setAudit(epAudit.jobs || []);
      if (status === "review") {
        setLinks(await get(`/api/episodes/${episode.id}/download`));
      } else {
        setLinks(null);
      }
      return "stop";
    }
    // failed
    const epAudit = await get(`/api/pipeline/status/${episode.id}`).catch(() => null);
    if (epAudit) setAudit(epAudit.jobs || []);
    return "stop";
  }, []);

  const poll = useCallback((id) => {
    stopPoll();
    pollRef.current = setInterval(async () => {
      try {
        const episode = await get(`/api/episodes/${id}`);
        const verdict = await applyStatus(episode);
        if (verdict === "stop") {
          stopPoll();
          if (episode.status === "script_ready") {
            toast("Scripts fertig – bitte prüfen, dann weiter", "ok");
          } else if (FINAL_STATUSES.includes(episode.status)) {
            toast("Sendung ist fertig!", "ok");
          }
        }
      } catch (err) {
        stopPoll();
        setEp((e) => (e ? { ...e, status: "failed", error: err.message } : e));
      }
    }, 3000);
  }, [applyStatus, stopPoll, toast]);

  // Sendung aus der Sendungen-Liste öffnen
  useEffect(() => {
    if (!openEpisodeId) return;
    stopPoll();
    setItems([]);
    setLinks(null);
    setAudit([]);
    (async () => {
      try {
        const episode = await get(`/api/episodes/${openEpisodeId}`);
        const verdict = await applyStatus(episode);
        if (verdict === "keep-polling") poll(openEpisodeId);
      } catch (err) {
        toast(err.message, "err");
      }
    })();
    onOpened();
  }, [openEpisodeId, applyStatus, poll, stopPoll, toast, onOpened]);

  useEffect(() => stopPoll, [stopPoll]);

  const createEpisode = async () => {
    if (!cityId) {
      toast("Keine Stadt vorhanden – unter Einstellungen anlegen", "err");
      return;
    }
    setCreating(true);
    setItems([]);
    setLinks(null);
    setAudit([]);
    try {
      const episode = await post("/api/episodes", {
        city_id: parseInt(cityId, 10),
        date: date || null,
        format,
        duration: parseInt(duration, 10),
      });
      await post(`/api/episodes/${episode.id}/generate`);
      setEp({ ...episode, status: "draft", error: null });
      toast("Pipeline gestartet – Status wird live angezeigt", "ok");
      poll(episode.id);
    } catch (err) {
      setEp((e) => (e ? { ...e, status: "failed", error: err.message } : { id: null, status: "failed", error: err.message }));
      toast(err.message, "err");
    } finally {
      setCreating(false);
    }
  };

  const continueEpisode = async () => {
    if (!ep) return;
    setActing(true);
    try {
      await post(`/api/episodes/${ep.id}/continue`);
      setEp({ ...ep, status: "voice_generating", error: null });
      setItems([]);
      toast("Sprecher & Video werden erzeugt", "ok");
      poll(ep.id);
    } catch (err) {
      toast(err.message, "err");
    } finally {
      setActing(false);
    }
  };

  const approveEpisode = async () => {
    if (!ep) return;
    setActing(true);
    try {
      await post(`/api/episodes/${ep.id}/approve`);
      setEp({ ...ep, status: "published" });
      setLinks(null);
      toast("Sendung freigegeben und veröffentlicht", "ok");
    } catch (err) {
      toast(err.message, "err");
    } finally {
      setActing(false);
    }
  };

  const steps = ep ? deriveSteps(ep.status) : [];
  const doneCount = steps.filter((s) => s.state === "done").length;
  const progress = ep ? Math.round((doneCount / STEPS.length) * 100) : 0;
  const isFinal = ep && FINAL_STATUSES.includes(ep.status);

  return (
    <section>
      <h1>Heutige Ausgabe</h1>
      <div className="grid-2">
        <div>
          <div className="panel">
            <h2>Sendung erstellen</h2>
            <div className="form-grid">
              <label>Stadt
                <select value={cityId} onChange={(e) => setCityId(e.target.value)}>
                  <option value="">– Stadt wählen –</option>
                  {cities.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
              </label>
              <label>Datum
                <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
              </label>
              <label>Format
                <select value={format} onChange={(e) => setFormat(e.target.value)}>
                  <option value="daily_news">Tagesnews</option>
                  <option value="breaking_news">Breaking News</option>
                </select>
              </label>
              <label>Länge
                <select value={duration} onChange={(e) => setDuration(e.target.value)}>
                  <option value="600">10 Minuten</option>
                  <option value="300">5 Minuten</option>
                  <option value="900">15 Minuten</option>
                </select>
              </label>
            </div>
            <button className="btn primary block" onClick={createEpisode} disabled={creating || !cityId}>
              {creating ? "PIPELINE GESTARTET …" : "SENDUNG GENERIEREN"}
            </button>
            <p className="muted small">Pipeline: News laden → Auswahl → Script → <em>Redaktions-Prüfung</em> → Sprecher → Video → Audio</p>
          </div>
        </div>

        <div>
          {ep && (
            <div className="panel">
              <h2>
                {ep.id ? `Ausgabe #${ep.id}` : "Fehler"}
                {ep.status === "script_ready" && <span className="badge warn head-badge">⏸ Wartet auf Redaktion</span>}
                {ep.status === "failed" && <span className="badge err head-badge">Fehler</span>}
                {isFinal && <span className="badge ok head-badge">{statusDe(ep.status)}</span>}
              </h2>
              <div className="progress"><div className="progress-bar" style={{ width: `${progress}%` }} /></div>
              <ul className="steps">
                {steps.map((s) => (
                  <li key={s.key} className={s.state}>
                    <span className="step-ico">{STEP_ICON[s.state]}</span> {s.label}
                    {s.state === "waiting" && <span className="muted small"> – Redaktion prüfen</span>}
                  </li>
                ))}
              </ul>
              {ep.error && <div className="error">Fehler: {ep.error}</div>}

              <div className="actions">
                {isFinal && links && (
                  <>
                    <a className="btn" href={links.video} target="_blank" rel="noreferrer">▶ VIDEO ANSEHEN</a>
                    <a className="btn" href={links.audio} target="_blank" rel="noreferrer">♪ AUDIO ANHÖREN</a>
                  </>
                )}
                {ep.status === "script_ready" && (
                  <button className="btn primary" onClick={continueEpisode} disabled={acting}>SPRECHER &amp; VIDEO ERZEUGEN</button>
                )}
                {ep.status === "review" && (
                  <button className="btn primary" onClick={approveEpisode} disabled={acting}>FREIGEBEN</button>
                )}
              </div>

              {audit.length > 0 && (
                <div className="audit">
                  <button className="audit-toggle" onClick={() => setShowAudit((v) => !v)}>
                    {showAudit ? "▾" : "▸"} Produktions-Protokoll ({audit.length} Jobs)
                  </button>
                  {showAudit && (
                    <table className="table audit-table">
                      <thead><tr><th>Schritt</th><th>Anbieter</th><th>Modell</th><th>Status</th></tr></thead>
                      <tbody>
                        {audit.map((j, i) => (
                          <tr key={i}>
                            <td>{JOBTYPE_DE[j.type] || j.type}</td>
                            <td className="muted">{j.provider}</td>
                            <td className="muted">{j.model || "–"}</td>
                            <td><span className={`badge ${j.status === "done" ? "ok" : "err"}`}>{j.status === "done" ? "OK" : "Fehler"}</span></td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  )}
                </div>
              )}
            </div>
          )}

          {ep && ep.status === "script_ready" && (
            <ScriptEditor items={items} episodeId={ep.id} onSaved={(it) => setItems((list) => list.map((x) => (x.id === it.id ? it : x)))} />
          )}
        </div>
      </div>
    </section>
  );
}

function ScriptEditor({ items, episodeId, onSaved }) {
  const toast = useToast();
  const [drafts, setDrafts] = useState({});
  const [saving, setSaving] = useState({});

  const draft = (it) => drafts[it.id] ?? { headline: it.headline || "", script: it.script || "" };
  const isDirty = (it) => {
    const d = draft(it);
    return d.headline !== (it.headline || "") || d.script !== (it.script || "");
  };

  const save = async (it) => {
    const d = draft(it);
    setSaving((s) => ({ ...s, [it.id]: true }));
    try {
      const updated = await patch(`/api/episodes/${episodeId}/items/${it.id}`, d);
      onSaved(updated);
      toast("Segment gespeichert", "ok");
    } catch (err) {
      toast(err.message, "err");
    } finally {
      setSaving((s) => ({ ...s, [it.id]: false }));
    }
  };

  if (!items.length) {
    return (
      <div className="panel">
        <h2>Sendeplan &amp; Sprechertexte (Redaktion)</h2>
        <p className="muted">Keine Segmente vorhanden – oben „Sprecher &amp; Video erzeugen" trotzdem möglich.</p>
      </div>
    );
  }

  return (
    <div className="panel">
      <h2>Sendeplan &amp; Sprechertexte (Redaktion)</h2>
      <p className="muted small">Texte prüfen und bei Bedarf ändern, <strong>bevor</strong> Sprecher &amp; Video erzeugt werden. Hinweis: Erneutes „Sendung generieren" baut den Plan neu und verwirft diese Änderungen.</p>
      {items.map((it) => {
        const d = draft(it);
        const dirty = isDirty(it);
        return (
          <div key={it.id} className={`item-card ${dirty ? "dirty" : ""}`}>
            <div className="item-head">
              <span className="seg-badge">{SEG_DE[it.seg_type] || it.seg_type}</span>
              <span className="muted">#{it.position + 1} · {it.duration || "?"}s · {statusDe(it.status)}</span>
              {dirty && <span className="badge warn">ungespeichert</span>}
            </div>
            <input
              type="text"
              className="item-headline"
              value={d.headline}
              placeholder="Headline"
              onChange={(e) => setDrafts((s) => ({ ...s, [it.id]: { ...d, headline: e.target.value } }))}
            />
            <textarea
              className="item-script"
              rows={3}
              placeholder="Sprechertext"
              value={d.script}
              onChange={(e) => setDrafts((s) => ({ ...s, [it.id]: { ...d, script: e.target.value } }))}
            />
            <button
              className="btn small"
              onClick={() => save(it)}
              disabled={!dirty || saving[it.id]}
            >
              {saving[it.id] ? "SPEICHERE …" : "TEXT SPEICHERN"}
            </button>
          </div>
        );
      })}
    </div>
  );
}
