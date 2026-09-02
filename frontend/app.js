/* Local Newsroom – Dashboard-Logik (Vanilla JS, keine Build-Tools nötig) */
"use strict";

const STEPS = [
  { key: "collecting",       label: "Nachrichten geladen" },
  { key: "selected",         label: "Auswahl getroffen" },
  { key: "script_ready",     label: "Scripts erstellt" },
  { key: "voice_ready",      label: "Sprecher erstellt" },
  { key: "rendering",        label: "Video produziert" },
  { key: "review",           label: "Audio produziert / Vorschau bereit" },
];

const DONE_OK = ["selected", "script_ready", "voice_ready", "rendered", "review", "approved", "published"];

let currentEpisode = null;
let pollTimer = null;

const $ = (id) => document.getElementById(id);

// ---------- Views ----------
document.querySelectorAll(".sidebar nav a").forEach((a) => {
  a.addEventListener("click", (e) => {
    if (!a.dataset.view) return;
    e.preventDefault();
    document.querySelectorAll(".sidebar nav a").forEach((x) => x.classList.remove("active"));
    a.classList.add("active");
    ["dashboard", "articles", "episodes"].forEach((v) => {
      $(`view-${v}`).hidden = v !== a.dataset.view;
    });
    if (a.dataset.view === "articles") loadArticles();
    if (a.dataset.view === "episodes") loadEpisodes();
  });
});

// ---------- API ----------
async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.detail || `${res.status} ${res.statusText}`);
  }
  return res.json();
}

// ---------- Dashboard ----------
async function loadCities() {
  const cities = await api("/api/cities");
  $("city").innerHTML = cities
    .map((c) => `<option value="${c.id}">${c.name}</option>`)
    .join("") || "<option>– keine Stadt vorhanden –</option>";
}

async function createEpisode() {
  const btn = $("btn-generate");
  btn.disabled = true;
  btn.textContent = "PIPELINE GESTARTET …";
  $("status-panel").hidden = false;
  $("status-error").hidden = true;
  $("btn-video").hidden = true;
  $("btn-audio").hidden = true;
  $("btn-approve").hidden = true;
  try {
    const payload = {
      city_id: parseInt($("city").value, 10),
      date: $("date").value || null,
      format: $("format").value,
      duration: parseInt($("duration").value, 10),
    };
    const episode = await api("/api/episodes", { method: "POST", body: JSON.stringify(payload) });
    await api(`/api/episodes/${episode.id}/generate`, { method: "POST" });
    currentEpisode = episode.id;
    $("status-title").textContent = `Ausgabe #${episode.id} – Produktion läuft`;
    pollStatus();
  } catch (err) {
    showError(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = "SENDUNG GENERIEREN";
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
          $("btn-video").href = links.video;
          $("btn-video").hidden = false;
          $("btn-audio").href = links.audio;
          $("btn-audio").hidden = false;
          $("btn-approve").hidden = ep.status !== "review";
        }
      }
    } catch (err) {
      clearInterval(pollTimer);
      showError(err.message);
    }
  }, 3000);
}

function updateStatusView(status, error) {
  const failed = status === "failed";
  const stepOrder = STEPS.map((s) => s.key);
  const currentIdx = stepOrder.indexOf(status);

  const items = STEPS.map((s, idx) => {
    let cls = "";
    let icon = "○";
    if (failed) {
      if (idx < currentIdx) { cls = "done"; icon = "✓"; }
      else if (idx === currentIdx) { cls = "failed"; icon = "✗"; }
    } else if (currentIdx === -1 && DONE_OK.includes(status)) {
      cls = "done"; icon = "✓";
    } else if (idx < currentIdx) {
      cls = "done"; icon = "✓";
    } else if (idx === currentIdx) {
      cls = "active"; icon = "→";
    } else if (DONE_OK.includes(status)) {
      cls = "done"; icon = "✓";
    }
    return `<li class="${cls}">${icon} ${s.label}</li>`;
  }).join("");
  $("step-list").innerHTML = items;

  const done = failed
    ? currentIdx
    : DONE_OK.includes(status) ? STEPS.length : currentIdx;
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
  } catch (err) {
    showError(err.message);
  }
}

// ---------- Nachrichten ----------
async function loadArticles() {
  const cityId = $("city").value;
  const articles = await api(`/api/articles?city_id=${cityId}&limit=100`);
  $("articles-meta").textContent = `${articles.length} Nachrichten geladen`;
  $("articles-table").querySelector("tbody").innerHTML = articles
    .map(
      (a) => `<tr>
        <td class="prio">${a.importance_score}</td>
        <td>${esc(a.title)}</td>
        <td>${esc(a.category || "–")}</td>
        <td><span class="badge ${a.status === "ai_processed" ? "ok" : ""}">${a.status}</span></td>
      </tr>`
    )
    .join("") || `<tr><td colspan="4" class="muted">Noch keine Nachrichten – „News jetzt laden" klicken.</td></tr>`;
}

async function importNews() {
  const btn = $("btn-import");
  btn.disabled = true;
  btn.textContent = "IMPORT LÄUFT …";
  try {
    await api("/api/pipeline/import", { method: "POST" });
    $("articles-meta").textContent = "Import gestartet – Liste in ca. 1 Minute aktualisieren";
    setTimeout(loadArticles, 60000);
  } catch (err) {
    alert(`Import fehlgeschlagen: ${err.message}`);
  } finally {
    btn.disabled = false;
    btn.textContent = "NEWS JETZT LADEN";
  }
}

// ---------- Sendungen ----------
async function loadEpisodes() {
  const episodes = await api("/api/episodes");
  const cities = await api("/api/cities");
  const cityName = (id) => (cities.find((c) => c.id === id) || {}).name || "–";
  const cls = (s) =>
    ["review", "approved", "published"].includes(s) ? "ok" : s === "failed" ? "err" : "active";
  $("episodes-table").querySelector("tbody").innerHTML = episodes
    .map(
      (e) => `<tr>
        <td>${e.id}</td>
        <td>${esc(cityName(e.city_id))}</td>
        <td>${e.date}</td>
        <td>${e.format}</td>
        <td><span class="badge ${cls(e.status)}">${e.status}</span></td>
        <td><button class="btn" onclick="openEpisode(${e.id})">ÖFFNEN</button></td>
      </tr>`
    )
    .join("") || `<tr><td colspan="6" class="muted">Noch keine Sendungen.</td></tr>`;
}

function openEpisode(id) {
  currentEpisode = id;
  $("status-panel").hidden = false;
  $("status-title").textContent = `Ausgabe #${id}`;
  pollStatus();
  document.querySelector('[data-view="dashboard"]').click();
}

function esc(s) {
  const d = document.createElement("div");
  d.textContent = s || "";
  return d.innerHTML;
}

// ---------- Init ----------
$("btn-generate").addEventListener("click", createEpisode);
$("btn-approve").addEventListener("click", approveEpisode);
$("btn-import").addEventListener("click", importNews);
$("date").value = new Date().toISOString().slice(0, 10);

loadCities();
