import React, { useCallback, useEffect, useState } from "react";
import { ToastProvider } from "./toast.jsx";
import Dashboard from "./views/Dashboard.jsx";
import Articles from "./views/Articles.jsx";
import Episodes from "./views/Episodes.jsx";
import Sources from "./views/Sources.jsx";
import Settings from "./views/Settings.jsx";
import { get } from "./api.js";

const VIEWS = [
  { key: "dashboard", label: "Dashboard", ico: "◉" },
  { key: "articles",  label: "Nachrichten", ico: "▤" },
  { key: "episodes",  label: "Sendungen", ico: "▣" },
  { key: "sources",   label: "Quellen", ico: "⇄" },
  { key: "settings",  label: "Einstellungen", ico: "⚙" },
];

export default function App() {
  const [view, setView] = useState("dashboard");
  const [backendOk, setBackendOk] = useState(false);
  const [cities, setCities] = useState([]);
  // Eine im Dashboard geöffnete Sendung – Episodes „Öffnen" setzt sie und springt herüber.
  const [openEpisodeId, setOpenEpisodeId] = useState(null);

  const refreshCities = useCallback(async () => {
    try {
      setCities(await get("/api/cities"));
      setBackendOk(true);
    } catch {
      setBackendOk(false);
    }
  }, []);

  useEffect(() => {
    refreshCities();
    const t = setInterval(() => get("/api/health").then(() => setBackendOk(true)).catch(() => setBackendOk(false)), 15000);
    return () => clearInterval(t);
  }, [refreshCities]);

  return (
    <ToastProvider>
      <div className="app">
        <aside className="sidebar">
          <div className="brand">
            <div className="brand-mark">LN</div>
            <div>LOCAL<br />NEWSROOM</div>
          </div>
          <nav>
            {VIEWS.map((v) => (
              <button
                key={v.key}
                className={`nav-item ${view === v.key ? "active" : ""}`}
                onClick={() => setView(v.key)}
              >
                <span className="ico">{v.ico}</span> {v.label}
              </button>
            ))}
          </nav>
          <div className="sidebar-footer">
            <span className={`status-dot ${backendOk ? "ok" : ""}`} />
            Backend {backendOk ? "online" : "offline"}
          </div>
        </aside>

        <main className="main">
          {view === "dashboard" && (
            <Dashboard cities={cities} refreshCities={refreshCities} openEpisodeId={openEpisodeId} onOpened={() => setOpenEpisodeId(null)} />
          )}
          {view === "articles"  && <Articles cities={cities} />}
          {view === "episodes"  && <Episodes cities={cities} onOpen={(id) => { setOpenEpisodeId(id); setView("dashboard"); }} />}
          {view === "sources"   && <Sources />}
          {view === "settings"  && <Settings cities={cities} refreshCities={refreshCities} />}
        </main>
      </div>
    </ToastProvider>
  );
}
