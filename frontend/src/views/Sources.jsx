import React, { useCallback, useEffect, useState } from "react";
import { get, post, patch, del } from "../api.js";
import { useToast } from "../toast.jsx";

export default function Sources() {
  const toast = useToast();
  const [sources, setSources] = useState(null);
  const [name, setName] = useState("");
  const [rss, setRss] = useState("");
  const [trust, setTrust] = useState(50);
  const [adding, setAdding] = useState(false);

  const load = useCallback(async () => {
    try {
      setSources(await get("/api/sources"));
    } catch (err) {
      toast(err.message, "err");
    }
  }, [toast]);

  useEffect(() => { load(); }, [load]);

  const addSource = async () => {
    if (!name.trim() || !rss.trim()) {
      toast("Name und RSS-URL ausfüllen", "err");
      return;
    }
    setAdding(true);
    try {
      await post("/api/sources", {
        name: name.trim(), type: "rss", rss_url: rss.trim(),
        trust_score: parseInt(trust, 10) || 50, active: true,
      });
      setName(""); setRss(""); setTrust(50);
      toast("Quelle hinzugefügt", "ok");
      load();
    } catch (err) {
      toast(err.message, "err");
    } finally {
      setAdding(false);
    }
  };

  // Partial-PATCH: nur den active-Status schicken (Backend seit Fix partial-fähig)
  const toggleSource = async (s) => {
    try {
      const updated = await patch(`/api/sources/${s.id}`, { active: !s.active });
      setSources((list) => list.map((x) => (x.id === updated.id ? updated : x)));
    } catch (err) {
      toast(err.message, "err");
    }
  };

  const removeSource = async (s) => {
    if (!window.confirm(`Quelle „${s.name}“ wirklich löschen?`)) return;
    try {
      await del(`/api/sources/${s.id}`);
      setSources((list) => list.filter((x) => x.id !== s.id));
      toast("Quelle gelöscht", "ok");
    } catch (err) {
      toast(err.message, "err");
    }
  };

  return (
    <section>
      <h1>Nachrichten-Quellen</h1>
      <div className="panel">
        <h2>Neue Quelle hinzufügen</h2>
        <div className="form-grid">
          <label>Name <input type="text" value={name} placeholder="z.B. Presseportal Polizei" onChange={(e) => setName(e.target.value)} /></label>
          <label>RSS-URL <input type="url" value={rss} placeholder="https://…/rss" onChange={(e) => setRss(e.target.value)} /></label>
          <label>Vertrauen (0–100) <input type="number" value={trust} min="0" max="100" onChange={(e) => setTrust(e.target.value)} /></label>
        </div>
        <button className="btn primary" onClick={addSource} disabled={adding}>QUELLE HINZUFÜGEN</button>
      </div>
      <div className="panel">
        <table className="table">
          <thead>
            <tr><th>Name</th><th>RSS-URL</th><th>Vertrauen</th><th>Aktiv</th><th></th></tr>
          </thead>
          <tbody>
            {(sources || []).map((s) => (
              <tr key={s.id}>
                <td>{s.name}</td>
                <td className="muted url-cell">{s.rss_url || s.url || "–"}</td>
                <td>{s.trust_score}</td>
                <td>
                  <label className="switch" title={s.active ? "Deaktivieren" : "Aktivieren"}>
                    <input type="checkbox" checked={s.active} onChange={() => toggleSource(s)} />
                    <span className="slider" />
                  </label>
                </td>
                <td>
                  <button className="btn small danger" onClick={() => removeSource(s)}>LÖSCHEN</button>
                </td>
              </tr>
            ))}
            {!sources?.length && (
              <tr><td colSpan={5} className="muted">{sources === null ? "Lade …" : "Keine Quellen."}</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
