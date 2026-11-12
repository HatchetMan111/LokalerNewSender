import React, { useCallback, useEffect, useState } from "react";
import { get, post, patch, del } from "../api.js";
import { useToast } from "../toast.jsx";

const CAT_TITLES = {
  ai: "KI / Texterstellung",
  tts: "Sprecher & Audio",
  video: "Video-Produktion",
  scheduler: "Automatik",
  episode: "Sendung",
  general: "Allgemein",
};

export default function Settings({ cities, refreshCities }) {
  const toast = useToast();
  const [settings, setSettings] = useState(null);
  const [registry, setRegistry] = useState(null);
  const [values, setValues] = useState({});
  const [savingKey, setSavingKey] = useState(null);
  const [savedKeys, setSavedKeys] = useState({});
  const [testing, setTesting] = useState({ llm: false, tts: false });
  const [testResult, setTestResult] = useState({ llm: null, tts: null });

  // Städte
  const [newCity, setNewCity] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const [all, reg] = await Promise.all([get("/api/settings"), get("/api/settings/registry")]);
        setSettings(all);
        setRegistry(reg);
        setValues(Object.fromEntries(all.map((s) => [s.key, s.value])));
      } catch (err) {
        toast(err.message, "err");
      }
    })();
  }, [toast]);

  const setValue = (key, value) => {
    setValues((v) => ({ ...v, [key]: value }));
    setSavedKeys((s) => ({ ...s, [key]: false }));
  };

  const saveSetting = async (key) => {
    setSavingKey(key);
    try {
      await patch(`/api/settings/${key}`, { value: values[key] ?? "" });
      setSavedKeys((s) => ({ ...s, [key]: true }));
      toast(`„${key}“ gespeichert`, "ok");
    } catch (err) {
      toast(err.message, "err");
    } finally {
      setSavingKey(null);
    }
  };

  const runTest = async (kind) => {
    setTesting((t) => ({ ...t, [kind]: true }));
    setTestResult((r) => ({ ...r, [kind]: null }));
    try {
      const res = await post(`/api/settings/test/${kind}`);
      setTestResult((r) => ({ ...r, [kind]: res }));
    } catch (err) {
      setTestResult((r) => ({ ...r, [kind]: { ok: false, error: err.message } }));
    } finally {
      setTesting((t) => ({ ...t, [kind]: false }));
    }
  };

  const addCity = async () => {
    if (!newCity.trim()) { toast("Stadtname fehlt", "err"); return; }
    try {
      await post("/api/cities", { name: newCity.trim() });
      setNewCity("");
      toast("Stadt hinzugefügt", "ok");
      refreshCities();
    } catch (err) {
      toast(err.message, "err");
    }
  };

  const removeCity = async (c) => {
    if (!window.confirm(`Stadt „${c.name}“ entfernen? (Sendungen bleiben im Archiv)`)) return;
    try {
      await del(`/api/cities/${c.id}`);
      toast("Stadt entfernt", "ok");
      refreshCities();
    } catch (err) {
      toast(err.message, "err");
    }
  };

  if (!settings || !registry) {
    return <section><h1>Einstellungen</h1><div className="panel muted">Lade …</div></section>;
  }

  // Gruppieren nach Kategorie (Reihenfolge wie im Backend sortiert)
  const groups = [];
  for (const s of settings) {
    let g = groups.find((x) => x.cat === s.category);
    if (!g) { g = { cat: s.category, items: [] }; groups.push(g); }
    g.items.push(s);
  }

  const renderControl = (s) => {
    const value = values[s.key] ?? s.value ?? "";
    const saved = savedKeys[s.key];

    if (s.key === "llm_provider") {
      return (
        <select value={value} onChange={(e) => setValue(s.key, e.target.value)}>
          {Object.entries(registry.llm).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
        </select>
      );
    }
    if (s.key === "llm_model") {
      const meta = registry.llm[values.llm_provider] || { models: [] };
      if (!meta.models.length) {
        return <input type="text" value={value} placeholder="Modellname, z.B. mein-modell" onChange={(e) => setValue(s.key, e.target.value)} />;
      }
      return (
        <select value={value} onChange={(e) => setValue(s.key, e.target.value)}>
          <option value="">Anbieter-Standard{meta.models[0] ? ` (${meta.models[0]})` : ""}</option>
          {!meta.models.includes(value) && value ? <option value={value}>{value} (aktuell)</option> : null}
          {meta.models.map((m) => <option key={m} value={m}>{m}</option>)}
        </select>
      );
    }
    if (s.key === "tts_provider") {
      return (
        <select value={value} onChange={(e) => setValue(s.key, e.target.value)}>
          {Object.entries(registry.tts).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
        </select>
      );
    }
    if (s.key === "tts_voice") {
      const meta = registry.tts[values.tts_provider] || { voices: [] };
      return (
        <select value={value} onChange={(e) => setValue(s.key, e.target.value)}>
          {!meta.voices.includes(value) && value ? <option value={value}>{value} (aktuell)</option> : null}
          {meta.voices.map((v) => <option key={v} value={v}>{v}</option>)}
        </select>
      );
    }
    if (s.key === "renderer_backend") {
      return (
        <select value={value} onChange={(e) => setValue(s.key, e.target.value)}>
          {Object.entries(registry.video.backends).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
      );
    }
    if (s.key === "subtitles") {
      return (
        <select value={value} onChange={(e) => setValue(s.key, e.target.value)}>
          {Object.entries(registry.video.subtitles || { off: "Aus", on: "An" }).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
      );
    }
    if (s.key === "video_style") {
      return (
        <select value={value} onChange={(e) => setValue(s.key, e.target.value)}>
          {registry.video.styles.map((st) => <option key={st} value={st}>{st}</option>)}
        </select>
      );
    }
    if (s.key === "video_resolution") {
      return (
        <select value={value} onChange={(e) => setValue(s.key, e.target.value)}>
          {registry.video.resolutions.map((r) => {
            const [w, h] = r.split("x").map(Number);
            const vertical = w && h && w < h;
            return <option key={r} value={r}>{r}{vertical ? " (vertikal 9:16)" : ""}</option>;
          })}
        </select>
      );
    }
    const placeholders = { tts_base_url: "http://localai:8080/v1", renderer_webhook_url: "https://mein-renderer/webhook" };
    return (
      <input
        type="text"
        value={value}
        placeholder={placeholders[s.key] || ""}
        onChange={(e) => setValue(s.key, e.target.value)}
      />
    );
  };

  const needsHint = {};
  Object.entries(registry.llm).forEach(([k, v]) => { needsHint[k] = v.needs.join(", "); });
  Object.entries(registry.tts).forEach(([k, v]) => { needsHint[`tts_${k}`] = v.needs.join(", "); });

  return (
    <section>
      <h1>Einstellungen</h1>
      {groups.map(({ cat, items }) => (
        <div className="panel" key={cat}>
          <h2>{CAT_TITLES[cat] || cat}</h2>
          {items.map((s) => (
            <div className="setting-row" key={s.key}>
              <div>
                <div className="setting-label">
                  {s.label || s.key}
                  {needsHint[s.key] && <span className="badge head-badge">benötigt: {needsHint[s.key]}</span>}
                </div>
                <div className="setting-desc">{s.description || ""}</div>
              </div>
              <div className="setting-control">{renderControl(s)}</div>
              <button
                className="btn small"
                onClick={() => saveSetting(s.key)}
                disabled={savingKey === s.key}
              >
                {savingKey === s.key ? "…" : savedKeys[s.key] ? "GESPEICHERT ✓" : "SPEICHERN"}
              </button>
            </div>
          ))}
          {cat === "ai" && (
            <div className="test-row">
              <button className="btn" onClick={() => runTest("llm")} disabled={testing.llm}>
                {testing.llm ? "TESTE …" : "KI-ANBIETER TESTEN"}
              </button>
              <TestResult kind="llm" result={testResult.llm} />
            </div>
          )}
          {cat === "tts" && (
            <div className="test-row">
              <button className="btn" onClick={() => runTest("tts")} disabled={testing.tts}>
                {testing.tts ? "ERZEUGE TESTAUFNAHME …" : "STIMME TESTEN (Anhören)"}
              </button>
              <TestResult kind="tts" result={testResult.tts} />
            </div>
          )}
        </div>
      ))}

      <div className="panel">
        <h2>Städte</h2>
        <div className="toolbar">
          <input
            type="text"
            className="inline-search"
            placeholder="z.B. Tauberbischofsheim"
            value={newCity}
            onChange={(e) => setNewCity(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && addCity()}
          />
          <button className="btn" onClick={addCity}>STADT HINZUFÜGEN</button>
        </div>
        <ul className="city-list">
          {cities.map((c) => (
            <li key={c.id}>
              <span>{c.name}{c.state ? <span className="muted"> · {c.state}</span> : null}</span>
              <button className="btn small danger" onClick={() => removeCity(c)}>ENTFERNEN</button>
            </li>
          ))}
          {!cities.length && <li className="muted">Noch keine Städte.</li>}
        </ul>
      </div>
    </section>
  );
}

function TestResult({ kind, result }) {
  if (!result) return null;
  if (result.ok) {
    if (kind === "llm") {
      return <span className="test-ok"><span className="badge ok">OK</span> {result.provider} · {result.model} → „{result.answer}“</span>;
    }
    return (
      <span className="test-ok">
        <span className="badge ok">OK</span>{" "}
        <a className="link" href={result.file_url} target="_blank" rel="noreferrer">Test anhören ({Math.round(result.file_bytes / 1024)} KB)</a>
      </span>
    );
  }
  return (
    <span className="test-err">
      <span className="badge err">FEHLER</span> {result.error}{result.fallback ? ` – Pipeline nutzt ${result.fallback}` : ""}
    </span>
  );
}
