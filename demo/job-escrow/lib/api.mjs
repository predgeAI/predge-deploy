// The Predge verdict API. A pilot key goes in `x-predge-key`; it comes from the environment and is never logged.
export async function requestVerdict(baseUrl, apiKey, body) {
  if (!apiKey) throw new Error("PREDGE_KEY is not set (free pilot key: predge.io/start)");
  const res = await fetch(`${baseUrl}/v1/verdicts`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-predge-key": apiKey },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`POST /v1/verdicts answered ${res.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text);
}

/** Read a stored verdict by id. Built from the id, never from a `verify_url` the response supplied. */
export async function fetchVerdict(baseUrl, id) {
  if (!/^vrd_[A-Za-z0-9_-]{24}$/.test(id)) throw new Error(`bad verdict id ${id}`);
  const res = await fetch(`${baseUrl}/v1/verdicts/${id}`);
  if (!res.ok) throw new Error(`GET /v1/verdicts/${id} answered ${res.status}`);
  return res.json();
}

export async function fetchKeyRegistry(baseUrl) {
  const res = await fetch(`${baseUrl}/.well-known/predge-keys.json`);
  if (!res.ok) throw new Error(`key registry answered ${res.status}`);
  return res.json();
}
