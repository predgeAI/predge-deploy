// LOCAL STAND-IN for api.predge.io, for the anvil demo only. It signs with a key made at startup, so nothing
// it signs verifies against Predge's published key. It implements the subset of the checks the demo uses and the
// same envelope and payload fields as the production route. The production API is what `--api live` calls.
import { createServer } from "node:http";
import { generateKeyPairSync, randomBytes, sign as edSign } from "node:crypto";
import { canonicalJson, sha256Hex } from "./verdict.mjs";

/** An ed25519 signer with a fresh random key. Not persisted anywhere. */
export function ephemeralSigner() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicKeyHex = publicKey.export({ format: "der", type: "spki" }).subarray(12).toString("hex");
  return { publicKeyHex, sign: (message) => edSign(null, Buffer.from(message, "utf8"), privateKey).toString("hex") };
}

const getPath = (obj, path) => path.split(".").reduce((o, k) => (o === null || o === undefined ? undefined : o[k]), obj);

function evaluate(job, delivery) {
  const checks = [];
  const add = (id, status, reason_code, detail) => checks.push({ id, status, reason_code, detail });
  const status = delivery.status;
  if (status >= 200 && status < 300) add("status_2xx", "pass", null, `HTTP ${status}`);
  else add("status_2xx", "fail", "status_not_2xx", `HTTP ${status}, not a 2xx success`);
  const body = typeof delivery.body === "string" ? delivery.body : "";
  if (body.length > 0) add("body_non_empty", "pass", null, `${Buffer.byteLength(body)} bytes`);
  else add("body_non_empty", "fail", "empty_body", "empty body");
  let parsed;
  try {
    parsed = JSON.parse(body);
    add("valid_json", "pass", null, "valid JSON");
  } catch {
    add("valid_json", "fail", "invalid_json", "not JSON");
  }
  for (const f of job.required_fields ?? []) {
    const v = getPath(parsed, f);
    if (v === undefined || v === null) add("required_fields", "fail", "required_field_missing", `${f} is missing`);
  }
  for (const f of job.non_empty_fields ?? []) {
    const v = getPath(parsed, f);
    const empty = v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0) || (typeof v === "object" && v !== null && Object.keys(v).length === 0);
    if (empty) add("non_empty_fields", "fail", "field_empty", `${f} is empty`);
  }
  if (job.max_latency_ms !== undefined) {
    if (delivery.latency_ms === undefined) add("latency", "inconclusive", "latency_unknown", "no latency evidence");
    else if (delivery.latency_ms > job.max_latency_ms) add("latency", "fail", "latency_exceeded", `${delivery.latency_ms} ms`);
    else add("latency", "pass", null, `${delivery.latency_ms} ms`);
  }
  const failed = checks.filter((c) => c.status === "fail");
  const unsure = checks.filter((c) => c.status === "inconclusive");
  if (failed.length) return { verdict: "not_delivered", reason_codes: [...new Set(failed.map((c) => c.reason_code))], checks };
  if (unsure.length) return { verdict: "inconclusive", reason_codes: unsure.map((c) => c.reason_code), checks };
  return { verdict: "delivered", reason_codes: ["all_checks_passed"], checks };
}

const usd = (n) => Number(n).toFixed(6);

/** A verdict in the production shape, signed by `signer`. Also used to forge one in the wrong-signer scene. */
export function buildVerdict(signer, req, overrides = {}) {
  const ev = evaluate(req.job, req.delivery);
  const id = `vrd_${randomBytes(18).toString("base64url")}`;
  const refundRecommended = ev.verdict === "not_delivered";
  const payload = {
    version: "predge-attest-v1",
    issuer: "predge.io",
    kind: "verdict",
    verdict_id: id,
    issued_at: new Date().toISOString(),
    verdict: ev.verdict,
    method: "schema",
    reason_codes: ev.reason_codes,
    checks: ev.checks,
    refund_recommended: refundRecommended,
    refund_amount_usd: usd(refundRecommended ? req.payment.amount_usd : 0),
    job: req.job,
    job_sha256: sha256Hex(canonicalJson(req.job)),
    delivery: {
      status: req.delivery.status,
      content_type: req.delivery.headers?.["content-type"],
      body_sha256: sha256Hex(req.delivery.body ?? ""),
      body_bytes: Buffer.byteLength(req.delivery.body ?? ""),
      latency_ms: req.delivery.latency_ms,
    },
    payment_ref: { ...req.payment, amount_usd: usd(req.payment.amount_usd) },
    buyer_id: req.buyer_id,
    merchant_id: req.merchant_id,
    agent: null,
    provider_agent: null,
    fee: { tier: "large", access: "pilot_key", price_usd: usd(0) },
    ...overrides,
  };
  const canonical = canonicalJson(payload);
  const attestation = {
    version: "predge-attest-v1",
    issuer: "predge.io",
    algorithm: "ed25519",
    kind: "verdict",
    data_basis: "LOCAL DEMO STAND-IN, not api.predge.io.",
    public_key: signer.publicKeyHex,
    canonical,
    signature: signer.sign(canonical),
    payload,
  };
  return { id, verdict: payload.verdict, reason_codes: payload.reason_codes, refund_recommended: refundRecommended, attestation };
}

export function startMockApi() {
  const signer = ephemeralSigner();
  const store = new Map();
  const send = (res, code, obj) => {
    res.writeHead(code, { "content-type": "application/json" });
    res.end(JSON.stringify(obj));
  };
  const server = createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      if (req.method === "GET" && req.url === "/.well-known/predge-keys.json") {
        return send(res, 200, { keys: [{ algorithm: "ed25519", public_key: signer.publicKeyHex, status: "active", role: "attestation" }] });
      }
      const m = /^\/v1\/verdicts\/(vrd_[\w-]{24})$/.exec(req.url);
      if (req.method === "GET" && m) return store.has(m[1]) ? send(res, 200, store.get(m[1])) : send(res, 404, { error: "not_found" });
      if (req.method === "POST" && req.url === "/v1/verdicts") {
        if (!req.headers["x-predge-key"]) return send(res, 402, { error: "payment_required" });
        const v = buildVerdict(signer, JSON.parse(Buffer.concat(chunks).toString("utf8")));
        store.set(v.id, v);
        return send(res, 200, v);
      }
      return send(res, 404, { error: "not_found" });
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve({ url: `http://127.0.0.1:${server.address().port}`, signer, close: () => server.close() });
    });
  });
}
