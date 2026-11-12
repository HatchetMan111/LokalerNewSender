import React, { useCallback, useEffect, useRef, useState } from "react";
import { get } from "../api.js";
import { useToast } from "../toast.jsx";
import { FORMAT_DE, statusDe } from "../labels.js";

// Alles ohne Endstatus gilt als „läuft“ → Liste aktualisiert sich dann selbst
const TERMINAL = new Set(["script_ready", "review", "approved", "published", "failed"]);

export default function Episodes({ cities, onOpen }) {
  const toast = useToast();
  const [episodes, setEpisodes] = useState(null);
  const timerRef = useRef(null);
  const hasRunningRef = useRef(false);
  hasRunningRef.current = (episodes || []).some((e) => !TERMINAL.has(e.status));

  const load = useCallback(async () => {
    try {
      setEpisodes(await get("/api/episodes"));
    } catch (err) {
      toast(err.message, "err");
    }
  }, [toast]);

  useEffect(() => {
    load();
    // Auto-Refresh, solange eine Pipeline läuft (Scheduler kann auch selbst starten)
    timerRef.current = setInterval(() => { if (hasRunningRef.current) load(); }, 5000);
    return () => clearInterval(timerRef.current);
  }, [load]);

  const cityName = (id) => (cities.find((c) => c.id === id) || {}).name || "–";
  const badgeCls = (s) => (["review", "approved", "published"].includes(s) ? "ok" : s === "failed" ? "err" : s === "script_ready" ? "warn" : "active");
  const dateDe = (d) => (d ? new Date(`${d}T00:00:00`).toLocaleDateString("de-DE") : "–");

  return (
    <section>
      <h1>Sendungen</h1>
      <div className="panel">
        <table className="table">
          <thead>
            <tr><th>ID</th><th>Stadt</th><th>Datum</th><th>Format</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {(episodes || []).map((e) => (
              <tr key={e.id}>
                <td className="muted">#{e.id}</td>
                <td>{cityName(e.city_id)}</td>
                <td>{dateDe(e.date)}</td>
                <td>{FORMAT_DE[e.format] || e.format}</td>
                <td><span className={`badge ${badgeCls(e.status)}`}>{statusDe(e.status)}</span></td>
                <td><button className="btn small" onClick={() => onOpen(e.id)}>ÖFFNEN</button></td>
              </tr>
            ))}
            {!episodes?.length && (
              <tr><td colSpan={6} className="muted">{episodes === null ? "Lade …" : "Noch keine Sendungen – im Dashboard generieren."}</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
