// Einheitlicher API-Layer: JSON-Fetch mit Fehlerbehandlung (FastAPI detail).
export async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    const detail = typeof body.detail === "string"
      ? body.detail
      : JSON.stringify(body.detail || body);
    throw new Error(detail || `${res.status} ${res.statusText}`);
  }
  return res.status === 204 ? null : res.json();
}

export const get = (path) => api(path);
export const post = (path, body) => api(path, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) });
export const patch = (path, body) => api(path, { method: "PATCH", body: JSON.stringify(body) });
export const del = (path) => api(path, { method: "DELETE" });
