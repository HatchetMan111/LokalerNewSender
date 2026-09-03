/* Local Newsroom – Dashboard-Logik */
"use strict";

const STEPS = [
  { key: "collecting",   label: "Nachrichten geladen" },
  { key: "selected",     label: "Auswahl getroffen" },
  { key: "script_ready", label: "Scripts erstellt" },
  { key: "voice_ready",  label: "Sprecher erstellt" },
  { key: "rendering",    label: "Video produziert" },
  { key: "review",       label: "Audio produziert / bereit zur Freigabe" },
];
const DONE_OK = ["selected", "script_ready", "voice_ready", "rendered", "review", "approved", "published"];
const VOICES = ["de-DE-KatjaNeural", "de-DE-ConradNeural", "de-DE-AmalaNeural", "de-DE-BerndNeural", "de-DE-ElkeNeural", "de-DE-KasperNeural", "de-DE-LeneNeural", "de-DE-RainerNeural"];

let currentEpisode = null;
let pollTimer = null;
let citiesCache = [];

const $ = (id) => document.getElementById(id);

// ------------------------------ Helpers ------------------------------------
function esc(s) { const d = document.createElement("div"); d.textContent = s || ""; return d.innerHTML; }

function toast(msg, type = "") {
  const t = $("toast");
  t.textContent = msg;
  t.className = `toast ${type}`;
  t.hidden = false;
  clearTimeout(t._timer);
  t._timer = setTimeout(() => (t.hidden = true), 4200);
}

async function api(path, options = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.detail || `${res.status} ${res.statusText}`);
  }
  return res.status === 204 ? null : res.json();
}

// ------------------------------ Navigation ---------------------------------
document.querySelectorAll(".sidebar nav a").forEach((a) => {
  a.addEventListener("click", (e) => {
    if (!a.dataset.view) return;
    e.preventDefault();
    document.querySelectorAll(".sidebar nav a").forEach((x) => x.classList.remove("active"));
    a.classList.add("active");
    ["dashboard", "articles", "episodes", "sources", "settings"].forEach((v) => {
      $(`view-${v}`).hidden = v !== a.dataset.view;
    });
    if (a.dataset.view === "articles") loadArticles();
    if (a.dataset.view === "episodes") loadEpisodes();
    if (a.dataset.view === "sources") loadSources();
    if (a.dataset.view === "settings") loadSettings();
  });
});

// ------------------------------ Dashboard ----------------------------------
async function loadCities() {
  try {
    citiesCache = await api("/api/cities");
    $("city").innerHTML = citiesCache.map((c) => `<option value="${c.id}">${esc(c.name)}</option>`).join("")
      || "<option>– keine Stadt –</option>";
    setBackendDot(true);
  } catch { setBackendDot(false); }
}

function setBackendDot(ok) { $("backend-dot").classList.toggle("ok", ok); }

async function createEpisode() {
  const btn = $("btn-generate");
  btn.disabled = true; btn.textContent = "PIPELINE GESTARTET …";
  $("status-panel").hidden = false;
  $("status-error").hidden = true;
  ["btn-video", "btn-audio", "btn-approve"].forEach((id) => ($(id).hidden = true));
  try {
    const payload = {
      city_id: parseInt($("city").value, 10),
      date: $("date").value || null,
      format: $("format").value,
      duration: parseInt($("duration").value, 10),
    };
    if (!payload.city_id) throw new Error("Keine Stadt vorhanden – unter Einstellungen anlegen");
    const episode = await api("/api/episodes", { method: "POST", body: JSON.stringify(payload) });
    await api(`/api/episodes/${episode.id}/generate`, { method: "POST" });
    currentEpisode = episode.id;
    $("status-title").textContent = `Ausgabe #${episode.id} – Produktion läuft`;
    toast("Pipeline gestartet – Status wird live angezeigt", "ok");
    pollStatus();
  } catch (err) {
    showError(err.message); toast(err.message, "err");
  } finally {
    btn.disabled = false; btn.textContent = "SENDUNG GENERIEREN";
  }
}

function pollStatus() {
  clearInterval(pollTimer);
  updateStatusView("draft", null);
  pollTimer = setInterval(async () => {
    try {
      const ep = await api(`/api/episodes/${currentEpisode}`);
      updateStatusView(ep.status, ep.error);
      if (["review", "approved", "published", "failed"].includes(ep.status)) {
        clearInterval(pollTimer);
        if (["review", "approved", "published"].includes(ep.status)) {
          const links = await api(`/api/episodes/${currentEpisode}/download`);
          $("btn-video").href = links.video; $("btn-video").hidden = false;
          $("btn-audio").href = links.audio; $("btn-audio").hidden = false;
          $("btn-approve").hidden = ep.status !== "review";
          toast("Sendung ist fertig!", "ok");
        }
      }
    } catch (err) { clearInterval(pollTimer); showError(err.message); }
  }, 3000);
}

function updateStatusView(status, error) {
  const failed = status === "failed";
  const stepOrder = STEPS.map((s) => s.key);
  const currentIdx = stepOrder.indexOf(status);

  $("step-list").innerHTML = STEPS.map((s, idx) => {
    let cls = "", icon = "○";
    if (failed) {
      if (idx < currentIdx) { cls = "done"; icon = "✓"; }
      else if (idx === currentIdx) { cls = "failed"; icon = "✗"; }
    } else if (idx < currentIdx || DONE_OK.includes(status)) { cls = "done"; icon = "✓"; }
    else if (idx === currentIdx) { cls = "active"; icon = "→"; }
    return `<li class="${cls}">${icon} ${s.label}</li>`;
  }).join("");

  const done = failed ? currentIdx : DONE_OK.includes(status) ? STEPS.length : currentIdx;
  $("progress-bar").style.width = `${Math.max(0, Math.min(100, (done / STEPS.length) * 100))}%`;

  if (failed && error) showError(error);
  else $("status-error").hidden = true;
}

function showError(msg) {
  $("status-error").textContent = `Fehler: ${msg}`;
  $("status-error").hidden = false;
}

async function approveEpisode() {
  try {
    await api(`/api/episodes/${currentEpisode}/approve`, { method: "POST" });
    $("btn-approve").hidden = true;
    updateStatusView("published", null);
    toast("Sendung freigegeben und veröffentlicht", "ok");
  } catch (err) { showError(err.message); }
}

// ------------------------------ Nachrichten --------------------------------
async function loadArticles() {
  const cityId = $("city").value;
  const q = cityId ? `?city_id=${cityId}&limit=100` : "?limit=100";
  const articles = await api(`/api/articles${q}`);
  $("articles-meta").textContent = `${articles.length} Nachrichten`;
  $("articles-table").querySelector("tbody").innerHTML = articles.map((a) => `<tr>
      <td class="prio">${a.importance_score}</td>
      <td>${esc(a.title)}</td>
      <td>${esc(a.category || "–")}</td>
      <td><span class="badge ${a.status === "ai_processed" ? "ok" : ""}">${a.status}</span></td>
    </tr>`).join("") || `<tr><td colspan="4" class="muted">Noch keine Nachrichten – „News jetzt laden" klicken.</td></tr>`;
}

async function importNews() {
  const btn = $("btn-import");
  btn.disabled = true; btn.textContent = "IMPORT LÄUFT …";
  try {
    await api("/api/pipeline/import", { method: "POST" });
    toast("Import gestartet – Liste aktualisiert sich in ~1 Minute", "ok");
    setTimeout(loadArticles, 60000);
  } catch (err) { toast(err.message, "err"); }
  finally { btn.disabled = false; btn.textContent = "NEWS JETZT LADEN"; }
}

// ------------------------------ Sendungen ----------------------------------
async function loadEpisodes() {
  const episodes = await api("/api/episodes");
  const cityName = (id) => (citiesCache.find((c) => c.id === id) || {}).name || "–";
  const cls = (s) => ["review", "approved", "published"].includes(s) ? "ok" : s === "failed" ? "err" : "active";
  $("episodes-table").querySelector("tbody").innerHTML = episodes.map((e) => `<tr>
      <td>${e.id}</td><td>${esc(cityName(e.city_id))}</td><td>${e.date}</td><td>${e.format}</td>
      <td><span class="badge ${cls(e.status)}">${e.status}</span></td>
      <td><button class="btn small" onclick="openEpisode(${e.id})">ÖFFNEN</button></td>
    </tr>`).join("") || `<tr><td colspan="6" class="muted">Noch keine Sendungen.</td></tr>`;
}

function openEpisode(id) {
  currentEpisode = id;
  $("status-panel").hidden = false;
  $("status-title").textContent = `Ausgabe #${id}`;
  pollStatus();
  document.querySelector('[data-view="dashboard"]').click();
}

// ------------------------------ Quellen ------------------------------------
async function loadSources() {
  const sources = await api("/api/sources");
  $("sources-table").querySelector("tbody").innerHTML = sources.map((s) => `<tr>
      <td>${esc(s.name)}</td><td class="muted">${esc(s.rss_url || s.url || "–")}</td><td>${s.trust_score}</td>
      <td><span class="badge ${s.active ? "ok" : ""}">${s.active ? "aktiv" : "aus"}</span></td>
      <td>
        <button class="btn small" onclick="toggleSource(${s.id}, ${!s.active})">${s.active ? "DEAKTIVIEREN" : "AKTIVIEREN"}</button>
        <button class="btn small danger" onclick="deleteSource(${s.id})">LÖSCHEN</button>
      </td>
    </tr>`).join("") || `<tr><td colspan="5" class="muted">Keine Quellen.</td></tr>`;
}

async function addSource() {
  const payload = {
    name: $("src-name").value.trim(),
    type: "rss",
    rss_url: $("src-rss").value.trim() || null,
    trust_score: parseInt($("src-trust").value, 10) || 50,
    active: true,
  };
  if (!payload.name || !payload.rss_url) return toast("Name und RSS-URL ausfüllen", "err");
  try {
    await api("/api/sources", { method: "POST", body: JSON.stringify(payload) });
    $("src-name").value = ""; $("src-rss").value = "";
    toast("Quelle hinzugefügt", "ok");
    loadSources();
  } catch (err) { toast(err.message, "err"); }
}

async function toggleSource(id, active) {
  const list = await api("/api/sources");
  const src = list.find((s) => s.id === id);
  if (!src) return;
  try {
    await api(`/api/sources/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ name: src.name, type: src.type, rss_url: src.rss_url, url: src.url, trust_score: src.trust_score, active }),
    });
    loadSources();
  } catch (err) { toast(err.message, "err"); }
}

async function deleteSource(id) {
  if (!confirm("Quelle wirklich löschen?")) return;
  try { await api(`/api/sources/${id}`, { method: "DELETE" }); loadSources(); }
  catch (err) { toast(err.message, "err"); }
}

// ------------------------------ Einstellungen ------------------------------
async function loadSettings() {
  const all = await api("/api/settings");
  const categories = {};
  all.forEach((s) => { (categories[s.category] = categories[s.category] || []).push(s); });

  const catTitles = { ai: "KI / Texterstellung", tts: "Sprecher & Audio", scheduler: "Automatik", episode: "Sendung", general: "Allgemein" };
  const selectOptions = {
    llm_provider: [["mock", "Mock (ohne API-Key)"], ["openai", "OpenAI"]],
    tts_voice: VOICES.map((v) => [v, v.replace("de-DE-", "").replace("Neural", "")]),
  };

  $("settings-panels").innerHTML = Object.entries(categories).map(([cat, items]) => `
    <div class="panel">
      <h2>${catTitles[cat] || cat}</h2>
      ${items.map((s) => `
        <div class="setting-row">
          <div>
            <div class="setting-label">${esc(s.label || s.key)}</div>
            <div class="setting-desc">${esc(s.description || "")}</div>
          </div>
          ${selectOptions[s.key]
            ? `<select data-setting="${s.key}">${selectOptions[s.key].map(([v, l]) => `<option value="${v}" ${v === s.value ? "selected" : ""}>${l}</option>`).join("")}</select>`
            : `<input type="text" data-setting="${s.key}" value="${esc(s.value)}">`}
          <button class="btn small" onclick="saveSetting('${s.key}')">SPEICHERN</button>
        </div>`).join("")}
    </div>`).join("");

  renderCityList();
}

async function saveSetting(key) {
  const el = document.querySelector(`[data-setting="${key}"]`);
  if (!el) return;
  try {
    await api(`/api/settings/${key}`, { method: "PATCH", body: JSON.stringify({ value: el.value }) });
    toast(`„${key}" gespeichert`, "ok");
  } catch (err) { toast(err.message, "err"); }
}

async function addCity() {
  const name = $("city-new").value.trim();
  if (!name) return toast("Stadtname fehlt", "err");
  try {
    await api("/api/cities", { method: "POST", body: JSON.stringify({ name }) });
    $("city-new").value = "";
    toast("Stadt hinzugefügt", "ok");
    loadCities(); renderCityList();
  } catch (err) { toast(err.message, "err"); }
}

async function deleteCity(id) {
  if (!confirm("Stadt entfernen? (Sendungen bleiben im Archiv)")) return;
  try { await api(`/api/cities/${id}`, { method: "DELETE" }); loadCities(); renderCityList(); }
  catch (err) { toast(err.message, "err"); }
}

async function renderCityList() {
  if (!citiesCache.length) citiesCache = await api("/api/cities").catch(() => []);
  $("city-list").innerHTML = citiesCache.map((c) => `
    <li><span>${esc(c.name)}${c.state ? ` <span class="muted">· ${esc(c.state)}</span>` : ""}</span>
    <button class="btn small danger" onclick="deleteCity(${c.id})">ENTFERNEN</button></li>`).join("");
}

// ------------------------------ Init ---------------------------------------
$("btn-generate").addEventListener("click", createEpisode);
$("btn-approve").addEventListener("click", approveEpisode);
$("btn-import").addEventListener("click", importNews);
$("btn-src-add").addEventListener("click", addSource);
$("btn-city-add").addEventListener("click", addCity);
$("date").value = new Date().toISOString().slice(0, 10);

loadCities();
setInterval(() => fetch("/api/health").then(() => setBackendDot(true)).catch(() => setBackendDot(false)), 15000);
