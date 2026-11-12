import React, { useCallback, useEffect, useRef, useState } from "react";
import { get, post } from "../api.js";
import { useToast } from "../toast.jsx";
import { ARTICLE_STATUS_DE } from "../labels.js";

const STATUS_FILTERS = [
  { key: "", value: "Alle" },
  { key: "raw", value: "Roh" },
  { key: "ai_processed", value: "KI-geprüft" },
  { key: "rejected_nonlocal", value: "Nicht lokal" },
];

export default function Articles({ cities }) {
  const toast = useToast();
  const [cityId, setCityId] = useState("");
  const [status, setStatus] = useState("");
  const [search, setSearch] = useState("");
  const [articles, setArticles] = useState(null);
  const [importing, setImporting] = useState(false);
  const pollRef = useRef(null);

  const load = useCallback(async () => {
    const params = new URLSearchParams({ limit: "100" });
    if (cityId) params.set("city_id", cityId);
    if (status) params.set("status", status);
    try {
      setArticles(await get(`/api/articles?${params}`));
    } catch (err) {
      setArticles([]);
      toast(err.message, "err");
    }
  }, [cityId, status, toast]);

  useEffect(() => {
    load();
    return () => clearInterval(pollRef.current);
  }, [load]);

  // Nach Import 3× im 20s-Abstand nachziehen (statt einmal starr nach 60s)
  const importNews = async () => {
    setImporting(true);
    try {
      await post("/api/pipeline/import");
      toast("Import gestartet – Liste aktualisiert sich automatisch", "ok");
      clearInterval(pollRef.current);
      let runs = 0;
      pollRef.current = setInterval(() => {
        load();
        if (++runs >= 3) { clearInterval(pollRef.current); setImporting(false); }
      }, 20000);
    } catch (err) {
      toast(err.message, "err");
      setImporting(false);
    }
  };

  const q = search.trim().toLowerCase();
  const visible = (articles || []).filter((a) =>
    !q || (a.title || "").toLowerCase().includes(q) || (a.location || "").toLowerCase().includes(q),
  );

  return (
    <section>
      <h1>Nachrichten</h1>
      <div className="panel">
        <div className="toolbar">
          <button className="btn primary" onClick={importNews} disabled={importing}>
            {importing ? "IMPORT LÄUFT …" : "NEWS JETZT LADEN"}
          </button>
          <select value={cityId} onChange={(e) => setCityId(e.target.value)} className="inline-select">
            <option value="">Alle Städte</option>
            {cities.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          <div className="chip-row">
            {STATUS_FILTERS.map((f) => (
              <button key={f.key} className={`chip ${status === f.key ? "active" : ""}`} onClick={() => setStatus(f.key)}>
                {f.value}
              </button>
            ))}
          </div>
          <input
            type="text"
            className="inline-search"
            placeholder="Suchen …"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <span className="muted">{visible.length} Nachrichten</span>
        </div>
        <table className="table">
          <thead>
            <tr><th>Prio</th><th>Titel</th><th>Kategorie</th><th>Status</th></tr>
          </thead>
          <tbody>
            {visible.map((a) => (
              <tr key={a.id}>
                <td className="prio">{a.importance_score}</td>
                <td>
                  {a.url
                    ? <a className="link" href={a.url} target="_blank" rel="noreferrer" title={a.ai_summary || a.title}>{a.title}</a>
                    : <span title={a.ai_summary || ""}>{a.title}</span>}
                </td>
                <td className="muted">{a.category || "–"}</td>
                <td>
                  <span className={`badge ${a.status === "ai_processed" ? "ok" : a.status === "rejected_nonlocal" ? "err" : ""}`}>
                    {ARTICLE_STATUS_DE[a.status] || a.status}
                  </span>
                </td>
              </tr>
            ))}
            {!visible.length && (
              <tr><td colSpan={4} className="muted">{articles === null ? "Lade …" : "Noch keine Nachrichten – „News jetzt laden“ klicken."}</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
