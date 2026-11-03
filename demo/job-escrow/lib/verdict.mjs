// Off-chain verdict checks. The contract cannot verify ed25519, so this file is where a verdict's
// signature, and its link to one specific job, are actually enforced. Format reference:
// docs/CANONICALIZATION.md and docs/verdicts.md in the Predge API.
import { createHash, createPublicKey, verify as edVerify } from "node:crypto";

export const Direction = Object.freeze({ None: 0, Refund: 1, Release: 2 });

export class VerdictRejected extends Error {
  constructor(code, message) {
    super(`${code}: ${message}`);
    this.code = code;
  }
}

const reject = (code, message) => {
  throw new VerdictRejected(code, message);
};

/** Same rule as the API's canonicalJson: sorted keys, no whitespace, undefined dropped. */
export function canonicalJson(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const parts = Object.keys(value)
    .sort()
    .filter((k) => value[k] !== undefined)
    .map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`);
  return `{${parts.join(",")}}`;
}

export const sha256Hex = (data) => createHash("sha256").update(data).digest("hex");

/** The on-chain `specHash`: the same bytes the API signs as `job_sha256`, with a 0x prefix. */
export const specHashOf = (jobSpec) => `0x${sha256Hex(canonicalJson(jobSpec))}`;

/** The on-chain evidence hash of a delivery: the same bytes the API signs as `delivery.body_sha256`. */
export const evidenceHashOf = (body) => `0x${sha256Hex(body)}`;

/** What `recordVerdict` stores: sha256 of the signed bytes (the envelope's `content_hash`). */
export const attestationHashOf = (attestation) => `0x${sha256Hex(attestation.canonical)}`;

const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function edVerifyHex(publicKeyHex, message, signatureHex) {
  const key = createPublicKey({
    key: Buffer.concat([SPKI_ED25519_PREFIX, Buffer.from(publicKeyHex, "hex")]),
    format: "der",
    type: "spki",
  });
  return edVerify(null, Buffer.from(message, "utf8"), key, Buffer.from(signatureHex, "hex"));
}

/**
 * From a /.well-known/predge-keys.json document, the keys that may sign verdicts. A revoked key is left
 * out however old the record is, because a leaked key can backdate. Retired keys stay valid for what they signed.
 */
export function trustedKeysFromRegistry(registry) {
  return (registry?.keys ?? [])
    .filter((k) => k.role === "attestation" && k.algorithm === "ed25519" && (k.status === "active" || k.status === "retired"))
    .map((k) => k.public_key.toLowerCase());
}

/**
 * Verify the envelope and return the SIGNED payload. Only the payload may be used afterwards: the
 * fields outside it, including the response's top-level `verdict`, are copies and are not signed.
 */
export function verifyAttestation(attestation, trustedKeys) {
  if (!attestation || typeof attestation !== "object") reject("no_attestation", "the response has no attestation");
  if (attestation.version !== "predge-attest-v1") reject("bad_version", `unknown version ${attestation.version}`);
  if (attestation.algorithm !== "ed25519") reject("bad_algorithm", `unknown algorithm ${attestation.algorithm}`);
  const { public_key: pk, signature, canonical, payload } = attestation;
  if (typeof pk !== "string" || !/^[0-9a-f]{64}$/i.test(pk)) reject("bad_key", "public_key is not a 32-byte hex key");
  if (typeof signature !== "string" || !/^[0-9a-f]{128}$/i.test(signature)) reject("bad_signature", "signature is not 64-byte hex");
  if (typeof canonical !== "string") reject("bad_canonical", "canonical is missing");
  if (!trustedKeys.includes(pk.toLowerCase())) reject("wrong_signer", `key ${pk.slice(0, 16)} is not a trusted Predge attestation key`);
  if (!edVerifyHex(pk, canonical, signature)) reject("bad_signature", "ed25519 signature does not verify");
  if (canonicalJson(payload) !== canonical) reject("payload_mismatch", "payload does not rebuild canonical");
  if (payload.kind !== "verdict") reject("not_a_verdict", `signed record has kind ${payload.kind}`);
  return payload;
}

/** The deterministic mapping. `inconclusive` has no direction: nothing goes on chain, a human looks at it. */
export function directionFor(payload) {
  switch (payload.verdict) {
    case "delivered":
      return Direction.Release;
    case "not_delivered":
      return Direction.Refund;
    case "inconclusive":
      return Direction.None;
    default:
      return reject("unknown_verdict", `unknown verdict ${payload.verdict}`);
  }
}

/** "10.000000" -> 10000000n. Refuses anything but a plain decimal, so no float ever touches an amount. */
export function usdToUnits(text) {
  const m = /^(\d+)(?:\.(\d{1,6}))?$/.exec(String(text));
  if (!m) reject("bad_amount", `amount ${text} is not a decimal with at most 6 places`);
  return BigInt(m[1]) * 1_000_000n + BigInt((m[2] ?? "").padEnd(6, "0"));
}

const same = (a, b) => String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();

/**
 * Tie a signed verdict to one job. A valid verdict about another job, another network or another amount
 * is rejected here. The API takes these fields from the caller and does not check them against a chain, so
 * this comparison is what gives them meaning.
 * @param job {specHash, refundTo, seller, amount (bigint, token units), chainId (number), payTxHash}
 */
export function checkBinding(payload, job) {
  if (!same(`0x${payload.job_sha256}`, job.specHash)) reject("wrong_job", "job_sha256 is not this job's specHash");
  const p = payload.payment_ref ?? {};
  if (!same(p.tx_hash, job.payTxHash)) reject("wrong_payment", `verdict is about payment ${p.tx_hash}, not ${job.payTxHash}`);
  if (p.network !== `eip155:${job.chainId}`) reject("wrong_network", `verdict is about ${p.network}, not eip155:${job.chainId}`);
  if (!same(p.payer, job.refundTo)) reject("wrong_payer", "payment_ref.payer is not the job's refundTo");
  if (!same(p.payee, job.seller)) reject("wrong_payee", "payment_ref.payee is not the job's seller");
  if (usdToUnits(p.amount_usd) !== job.amount) reject("wrong_amount", `verdict amount ${p.amount_usd} does not match the job`);
  const body = payload.delivery?.body_sha256;
  if (typeof body !== "string" || !/^[0-9a-f]{64}$/i.test(body)) reject("no_evidence_hash", "the verdict has no delivery.body_sha256 to cite");
  return { evidenceHash: `0x${body.toLowerCase()}` };
}
