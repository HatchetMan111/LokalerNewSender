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

const STATUS_DE = {draft: "Entwurf", collecting: "Sammelt News", selected: "Auswahl steht", scripting: "Schreibt Scripts", script_ready: "Script bereit zur Prüfung", voice_generating: "Erzeugt Sprecher", voice_ready: "Sprecher fertig", rendering: "Rendert Video", rendered: "Gerendert", review: "Bereit zur Freigabe", approved: "Freigegeben", published: "Veröffentlicht", failed: "Fehler"};
const FORMAT_DE = {daily_news: "Tagesnews", breaking_news: "Breaking News"};
const ARTICLE_STATUS_DE = {raw: "Roh", ai_processed: "KI-geprüft", editor_approved: "Redaktion-OK", published: "Veröffentlicht", rejected_nonlocal: "Nicht lokal"};
const statusDe = (s) => STATUS_DE[s] || s;

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
  ["btn-video", "btn-audio", "btn-approve", "btn-continue"].forEach((id) => ($(id).hidden = true));
  $("items-panel").hidden = true;
  $("items-list").innerHTML = "";
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
      if (ep.status === "script_ready") {
        clearInterval(pollTimer);
        $("status-title").textContent = `Ausgabe #${ep.id} – Scripts prüfen`;
        $("btn-continue").hidden = false;
        await loadItems();
        toast("Scripts fertig – bitte prüfen, dann weiter", "ok");
      } else if (["review", "approved", "published", "failed"].includes(ep.status)) {
        clearInterval(pollTimer);
        if (["review", "approved", "published"].includes(ep.status)) {
          const links = await api(`/api/episodes/${currentEpisode}/download`);
          $("btn-video").href = links.video; $("btn-video").hidden = false;
          $("btn-audio").href = links.audio; $("btn-audio").hidden = false;
          $("btn-approve").hidden = ep.status !== "review";
          $("btn-continue").hidden = true;
          toast("Sendung ist fertig!", "ok");
        }
      }
    } catch (err) { clearInterval(pollTimer); showError(err.message); }
  }, 3000);
}

async function continueEpisode() {
  $("btn-continue").hidden = true;
  $("status-title").textContent = `Ausgabe #${currentEpisode} – Produktion läuft`;
  try {
    await api(`/api/episodes/${currentEpisode}/continue`, { method: "POST" });
    toast("Sprecher & Video werden erzeugt", "ok");
    pollStatus();
  } catch (err) { showError(err.message); toast(err.message, "err"); }
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

// ------------------------------ Sendeplan-Editor -----------------------------
const SEG_DE = {intro: "Intro", news: "News", weather: "Wetter", outro: "Outro"};

async function loadItems() {
  if (!currentEpisode) return;
  const items = await api(`/api/episodes/${currentEpisode}/items`);
  if (!items.length) return;
  $("items-panel").hidden = false;
  $("items-list").innerHTML = items.map((it) => `
    <div class="item-card" data-item="${it.id}">
      <div class="item-head">
        <span class="seg-badge">${SEG_DE[it.seg_type] || it.seg_type}</span>
        <span class="muted">#${it.position + 1} · ${it.duration || "?"}s · ${statusDe(it.status)}</span>
      </div>
      <input type="text" class="item-headline" value="${esc(it.headline || "")}" placeholder="Headline">
      <textarea class="item-script" rows="3" placeholder="Sprechertext">${esc(it.script || "")}</textarea>
      <button class="btn small" onclick="saveItem(${it.id})">TEXT SPEICHERN</button>
    </div>`).join("");
}

async function saveItem(itemId) {
  const card = document.querySelector(`[data-item="${itemId}"]`);
  if (!card) return;
  const headline = card.querySelector(".item-headline").value;
  const script = card.querySelector(".item-script").value;
  try {
    await api(`/api/episodes/${currentEpisode}/items/${itemId}`, {
      method: "PATCH", body: JSON.stringify({ headline, script }),
    });
    toast("Segment gespeichert", "ok");
  } catch (err) { toast(err.message, "err"); }
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
      <td><span class="badge ${a.status === "ai_processed" ? "ok" : ""}">${ARTICLE_STATUS_DE[a.status] || a.status}</span></td>
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
      <td>${e.id}</td><td>${esc(cityName(e.city_id))}</td><td>${e.date}</td><td>${FORMAT_DE[e.format] || e.format}</td>
      <td><span class="badge ${cls(e.status)}">${statusDe(e.status)}</span></td>
      <td><button class="btn small" onclick="openEpisode(${e.id})">ÖFFNEN</button></td>
    </tr>`).join("") || `<tr><td colspan="6" class="muted">Noch keine Sendungen.</td></tr>`;
}

function openEpisode(id) {
  currentEpisode = id;
  $("status-panel").hidden = false;
  $("items-panel").hidden = true;
  $("items-list").innerHTML = "";
  ["btn-video", "btn-audio", "btn-approve", "btn-continue"].forEach((x) => ($(x).hidden = true));
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
let REGISTRY = null;

async function loadSettings() {
  const [all, reg] = await Promise.all([api("/api/settings"), api("/api/settings/registry")]);
  REGISTRY = reg;

  const catTitles = { ai: "KI / Texterstellung", tts: "Sprecher & Audio", video: "Video-Produktion", scheduler: "Automatik", episode: "Sendung", general: "Allgemein" };
  const rows = {
    llm_provider: { kind: "select", options: Object.entries(reg.llm).map(([k, v]) => [k, v.label]) },
    llm_model: { kind: "select", options: [], dynamic: "llm_model" },
    tts_provider: { kind: "select", options: Object.entries(reg.tts).map(([k, v]) => [k, v.label]) },
    tts_voice: { kind: "select", options: [], dynamic: "tts_voice" },
    tts_model: { kind: "text" },
    tts_base_url: { kind: "text", placeholder: "http://localai:8080/v1" },
    renderer_backend: { kind: "select", options: Object.entries(reg.video.backends).map(([k, v]) => [k, v]) },
    renderer_webhook_url: { kind: "text", placeholder: "https://mein-renderer/webhook" },
    video_style: { kind: "select", options: reg.video.styles.map((s) => [s, s]) },
    video_resolution: { kind: "select", options: reg.video.resolutions.map((r) => [r, r + (r.includes("x") && parseInt(r.split("x")[0]) < parseInt(r.split("x")[1]) ? " (vertikal 9:16)" : "")]) },
    import_interval_minutes: { kind: "text" },
    target_duration: { kind: "text" },
  };

  const needsHint = {};
  Object.entries(reg.llm).forEach(([k, v]) => { needsHint[k] = v.needs.join(", "); });
  Object.entries(reg.tts).forEach(([k, v]) => { needsHint["tts_" + k] = v.needs.join(", "); });

  $("settings-panels").innerHTML = Object.entries(groupBy(all, "category")).map(([cat, items]) => `
    <div class="panel">
      <h2>${catTitles[cat] || cat}</h2>
      ${items.map((s) => {
        const cfg = rows[s.key] || { kind: "text" };
        const hint = needsHint[s.key === "llm_provider" ? s.value : s.key] || needsHint[s.key];
        return `
        <div class="setting-row">
          <div>
            <div class="setting-label">${esc(s.label || s.key)}${hint ? ` <span class="badge">benötigt: ${esc(hint)}</span>` : ""}</div>
            <div class="setting-desc">${esc(s.description || "")}</div>
          </div>
          ${cfg.kind === "select"
            ? `<select data-setting="${s.key}">${(cfg.options || []).map(([v, l]) => `<option value="${v}" ${v === s.value ? "selected" : ""}>${l}</option>`).join("")}</select>`
            : `<input type="text" data-setting="${s.key}" value="${esc(s.value)}" placeholder="${esc(cfg.placeholder || "")}">`}
          <button class="btn small" onclick="saveSetting('${s.key}')">SPEICHERN</button>
        </div>`;
      }).join("")}
      ${cat === "ai" ? `<div class="test-row"><button class="btn" onclick="testLLM()">KI-ANBIETER TESTEN</button><span id="llm-test-result" class="muted"></span></div>` : ""}
      ${cat === "tts" ? `<div class="test-row"><button class="btn" onclick="testTTS()">STIMME TESTEN (Anhören)</button><span id="tts-test-result" class="muted"></span></div>` : ""}
    </div>`).join("");

  // Dynamische Optionen nachziehen (Modelle/Stimmen je nach gewähltem Anbieter)
  updateDynamicOptions();
  ["llm_provider", "tts_provider"].forEach((k) => {
    document.querySelector(`[data-setting="${k}"]`)?.addEventListener("change", updateDynamicOptions);
  });

  renderCityList();
}

function groupBy(arr, key) {
  const out = {};
  arr.forEach((item) => { (out[item[key]] = out[item[key]] || []).push(item); });
  return out;
}

function updateDynamicOptions() {
  if (!REGISTRY) return;
  const llmSel = document.querySelector('[data-setting="llm_provider"]');
  const modelSel = document.querySelector('[data-setting="llm_model"]');
  if (llmSel && modelSel) {
    const provider = llmSel.value;
    const meta = REGISTRY.llm[provider] || { models: [] };
    const current = modelSel.value || "";
    if (!meta.models.length) {
      // Custom-Anbieter: Modellname frei eintippen (z.B. eigenes LocalAI-Modell)
      const input = document.createElement("input");
      input.type = "text";
      input.setAttribute("data-setting", "llm_model");
      input.placeholder = "Modellname, z.B. mein-modell";
      input.value = current;
      modelSel.replaceWith(input);
    } else {
      const opts = meta.models.includes(current) || !current ? "" : `<option value="${esc(current)}" selected>${esc(current)} (aktuell)</option>`;
      modelSel.innerHTML =
        `<option value="">Anbieter-Standard${meta.models[0] ? ` (${meta.models[0]})` : ""}</option>` +
        meta.models.map((m) => `<option value="${m}" ${m === current ? "selected" : ""}>${m}</option>`).join("") + opts;
    }
  }
  const ttsSel = document.querySelector('[data-setting="tts_provider"]');
  const voiceSel = document.querySelector('[data-setting="tts_voice"]');
  if (ttsSel && voiceSel) {
    const provider = ttsSel.value;
    const meta = REGISTRY.tts[provider] || { voices: [] };
    const current = voiceSel.value || "";
    const extra = (!current || meta.voices.includes(current)) ? "" : `<option value="${esc(current)}" selected>${esc(current)} (aktuell)</option>`;
    voiceSel.innerHTML = meta.voices.map((v) => `<option value="${v}" ${v === current ? "selected" : ""}>${v}</option>`).join("") + extra;
  }
}

async function saveSetting(key) {
  const el = document.querySelector(`[data-setting="${key}"]`);
  if (!el) return;
  try {
    await api(`/api/settings/${key}`, { method: "PATCH", body: JSON.stringify({ value: el.value }) });
    toast(`„${key}" gespeichert`, "ok");
    if (key === "llm_provider" || key === "tts_provider") updateDynamicOptions();
  } catch (err) { toast(err.message, "err"); }
}

async function testLLM() {
  const span = $("llm-test-result");
  span.textContent = "Teste …";
  try {
    const res = await api("/api/settings/test/llm", { method: "POST" });
    if (res.ok) span.innerHTML = `<span class="badge ok">OK</span> ${esc(res.provider)} · ${esc(res.model)} → „${esc(res.answer)}"`;
    else span.innerHTML = `<span class="badge err">FEHLER</span> ${esc(res.error)}${res.fallback ? " – Pipeline nutzt Mock" : ""}`;
  } catch (err) { span.innerHTML = `<span class="badge err">FEHLER</span> ${esc(err.message)}`; }
}

async function testTTS() {
  const span = $("tts-test-result");
  span.textContent = "Erzeuge Testaufnahme …";
  try {
    const res = await api("/api/settings/test/tts", { method: "POST" });
    if (res.ok) {
      span.innerHTML = `<span class="badge ok">OK</span> <a href="${res.file_url}" target="_blank" class="link">Test anhören (${Math.round(res.file_bytes / 1024)} KB)</a>`;
    } else {
      span.innerHTML = `<span class="badge err">FEHLER</span> ${esc(res.error)}${res.fallback ? " – Pipeline nutzt Edge" : ""}`;
    }
  } catch (err) { span.innerHTML = `<span class="badge err">FEHLER</span> ${esc(err.message)}`; }
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
$("btn-continue").addEventListener("click", continueEpisode);
$("btn-import").addEventListener("click", importNews);
$("btn-src-add").addEventListener("click", addSource);
$("btn-city-add").addEventListener("click", addCity);
$("date").value = new Date().toISOString().slice(0, 10);

loadCities();
setInterval(() => fetch("/api/health").then(() => setBackendDot(true)).catch(() => setBackendDot(false)), 15000);
