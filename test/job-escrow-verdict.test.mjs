// Off-chain half of "wrong signer" and "replayed verdict": the contract cannot check ed25519, so this is enforced here.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { guardKey, guardNetwork, FORBIDDEN_KEYS, isLocalRpc } from "../demo/job-escrow/lib/chain.mjs";
import { nextAction } from "../demo/job-escrow/lib/keeper.mjs";
import { buildVerdict, ephemeralSigner } from "../demo/job-escrow/lib/mock-api.mjs";
import {
  attestationHashOf,
  canonicalJson,
  checkBinding,
  Direction,
  directionFor,
  evidenceHashOf,
  sha256Hex,
  specHashOf,
  trustedKeysFromRegistry,
  usdToUnits,
  VerdictRejected,
  verifyAttestation,
} from "../demo/job-escrow/lib/verdict.mjs";

const SELLER = "0x00000000000000000000000000000000000000aA";
const REFUND_TO = "0x00000000000000000000000000000000000000bB";
const TX = `0x${"ab".repeat(32)}`;
const spec = { endpoint: "https://seller.demo.invalid/v1/report", required_fields: ["rows"], non_empty_fields: ["rows"] };
const signer = ephemeralSigner();
const TRUSTED = [signer.publicKeyHex];

const request = (body = '{"rows":[1]}') => ({
  job: spec,
  delivery: { status: 200, headers: { "content-type": "application/json" }, body, latency_ms: 5 },
  payment: { tx_hash: TX, network: "eip155:5042002", amount_usd: 10, payer: REFUND_TO, payee: SELLER },
});
const job = { specHash: specHashOf(spec), refundTo: REFUND_TO, seller: SELLER, amount: 10_000_000n, chainId: 5042002, payTxHash: TX };
const rejectedWith = (code) => (e) => e instanceof VerdictRejected && e.code === code;

test("a genuine verdict verifies and binds to its job", () => {
  const v = buildVerdict(signer, request());
  const payload = verifyAttestation(v.attestation, TRUSTED);
  assert.equal(payload.verdict, "delivered");
  assert.equal(checkBinding(payload, job).evidenceHash, evidenceHashOf('{"rows":[1]}'));
});

test("wrong signer: a valid signature by an untrusted key is refused", () => {
  const v = buildVerdict(ephemeralSigner(), request());
  assert.throws(() => verifyAttestation(v.attestation, TRUSTED), rejectedWith("wrong_signer"));
});

test("wrong signer: naming a trusted key without its signature is refused", () => {
  const v = buildVerdict(ephemeralSigner(), request());
  v.attestation.public_key = signer.publicKeyHex;
  assert.throws(() => verifyAttestation(v.attestation, TRUSTED), rejectedWith("bad_signature"));
});

test("tampering: payload, canonical and signature", () => {
  const a = buildVerdict(signer, request());
  a.attestation.payload.verdict = "not_delivered";
  assert.throws(() => verifyAttestation(a.attestation, TRUSTED), rejectedWith("payload_mismatch"));
  const b = buildVerdict(signer, request());
  b.attestation.canonical = b.attestation.canonical.replace('"delivered"', '"not_delivered"');
  assert.throws(() => verifyAttestation(b.attestation, TRUSTED), rejectedWith("bad_signature"));
  const c = buildVerdict(signer, request());
  c.attestation.signature = "00".repeat(64);
  assert.throws(() => verifyAttestation(c.attestation, TRUSTED), rejectedWith("bad_signature"));
});

test("only the signed payload counts, not the top-level copy", () => {
  const v = buildVerdict(signer, request('{"rows":[]}'));
  v.verdict = "delivered"; // unsigned copy, edited
  assert.equal(directionFor(verifyAttestation(v.attestation, TRUSTED)), Direction.Refund);
});

test("malformed envelopes and other record kinds are refused", () => {
  assert.throws(() => verifyAttestation(undefined, TRUSTED), rejectedWith("no_attestation"));
  const base = buildVerdict(signer, request()).attestation;
  assert.throws(() => verifyAttestation({ ...base, version: "v9" }, TRUSTED), rejectedWith("bad_version"));
  assert.throws(() => verifyAttestation({ ...base, algorithm: "rsa" }, TRUSTED), rejectedWith("bad_algorithm"));
  assert.throws(() => verifyAttestation({ ...base, public_key: "zz" }, TRUSTED), rejectedWith("bad_key"));
  const other = buildVerdict(signer, request(), { kind: "verdict_report" }).attestation;
  assert.throws(() => verifyAttestation(other, TRUSTED), rejectedWith("not_a_verdict"));
});

test("replay: a genuine verdict about something else does not bind", () => {
  const payload = verifyAttestation(buildVerdict(signer, request()).attestation, TRUSTED);
  assert.throws(() => checkBinding(payload, { ...job, specHash: specHashOf({ endpoint: "https://other.invalid" }) }), rejectedWith("wrong_job"));
  assert.throws(() => checkBinding(payload, { ...job, payTxHash: `0x${"cd".repeat(32)}` }), rejectedWith("wrong_payment"));
  assert.throws(() => checkBinding(payload, { ...job, chainId: 5042 }), rejectedWith("wrong_network"));
  assert.throws(() => checkBinding(payload, { ...job, refundTo: SELLER }), rejectedWith("wrong_payer"));
  assert.throws(() => checkBinding(payload, { ...job, seller: REFUND_TO }), rejectedWith("wrong_payee"));
  assert.throws(() => checkBinding(payload, { ...job, amount: 9_999_999n }), rejectedWith("wrong_amount"));
});

test("binding is case-insensitive for addresses and hex", () => {
  const payload = verifyAttestation(buildVerdict(signer, request()).attestation, TRUSTED);
  assert.ok(checkBinding(payload, { ...job, refundTo: REFUND_TO.toLowerCase(), specHash: job.specHash.toUpperCase().replace("0X", "0x") }));
});

test("a verdict without a body hash has nothing to cite", () => {
  const v = buildVerdict(signer, request(), { delivery: { status: 200, body_sha256: null } });
  assert.throws(() => checkBinding(verifyAttestation(v.attestation, TRUSTED), job), rejectedWith("no_evidence_hash"));
});

test("the verdict maps deterministically; inconclusive and unknown never rule", () => {
  assert.equal(directionFor({ verdict: "delivered" }), Direction.Release);
  assert.equal(directionFor({ verdict: "not_delivered" }), Direction.Refund);
  assert.equal(directionFor({ verdict: "inconclusive" }), Direction.None);
  assert.throws(() => directionFor({ verdict: "maybe" }), rejectedWith("unknown_verdict"));
});

test("amounts are parsed without floats", () => {
  assert.equal(usdToUnits("10.000000"), 10_000_000n);
  assert.equal(usdToUnits("0.1"), 100_000n);
  assert.equal(usdToUnits("1234567.000001"), 1_234_567_000_001n);
  for (const bad of ["1e6", "-1", "1.0000001", "", "abc"]) assert.throws(() => usdToUnits(bad), rejectedWith("bad_amount"));
});

test("the registry: revoked keys and other roles are not trusted", () => {
  const keys = trustedKeysFromRegistry({
    keys: [
      { role: "attestation", algorithm: "ed25519", status: "active", public_key: "AA" },
      { role: "attestation", algorithm: "ed25519", status: "retired", public_key: "bb" },
      { role: "attestation", algorithm: "ed25519", status: "revoked", public_key: "cc" },
      { role: "cachet-oracle", algorithm: "ed25519", status: "active", public_key: "dd" },
    ],
  });
  assert.deepEqual(keys, ["aa", "bb"]);
});

test("a real production verdict verifies, and the mock has the same signed fields", () => {
  // From the public "Try it now" route, predge.io/api/demo-verdict, 4 Nov 2026. Public by design.
  const { request: req, verdict } = JSON.parse(readFileSync(new URL("./fixtures/real-verdict-demo.json", import.meta.url), "utf8"));
  const PRODUCTION_KEY = "3b6551a6439b9bda0de7e3b8dc89f276b2141fdfde310f762e663ab4ba2e9d1b"; // published at /.well-known/predge-keys.json
  const payload = verifyAttestation(verdict.attestation, [PRODUCTION_KEY]);
  assert.equal(payload.verdict, "not_delivered");
  assert.equal(directionFor(payload), Direction.Refund);
  assert.equal(`0x${payload.job_sha256}`, specHashOf(req.job), "our specHash is the API's job_sha256");
  assert.equal(`0x${payload.delivery.body_sha256}`, evidenceHashOf(req.delivery.body), "our evidence hash is the API's body_sha256");
  assert.equal(attestationHashOf(verdict.attestation), `0x${verdict.attestation.content_hash}`, "our attestation hash is its content_hash");
  assert.equal(sha256Hex(canonicalJson(payload)), verdict.attestation.content_hash);
  assert.throws(() => verifyAttestation(verdict.attestation, TRUSTED), rejectedWith("wrong_signer"));
  const mock = buildVerdict(signer, { ...req, payment: { ...req.payment } }).attestation.payload;
  for (const field of ["kind", "verdict_id", "verdict", "reason_codes", "job", "job_sha256", "delivery", "payment_ref", "fee"]) {
    assert.ok(field in payload, `production has ${field}`);
    assert.ok(field in mock, `mock has ${field}`);
  }
});

test("keeper decisions", () => {
  const job0 = { state: 1n, delivered: false, deliverBy: 100n, releaseAt: 1000n };
  const none = { status: 0n };
  const ruled = { status: 1n, ruledAt: 50n, window: 10n, expiresAt: 500n };
  assert.equal(nextAction({ ...job0, state: 2n }, none, 9999n), null, "done");
  assert.equal(nextAction(job0, none, 100n), null, "on the deadline is not past it");
  assert.equal(nextAction(job0, none, 101n), "refundAfterDeadline");
  assert.equal(nextAction({ ...job0, delivered: true }, none, 999n), null);
  assert.equal(nextAction({ ...job0, delivered: true }, none, 1000n), "releaseAfterBackstop");
  assert.equal(nextAction(job0, ruled, 59n), null, "window open");
  assert.equal(nextAction(job0, ruled, 60n), "settle");
  assert.equal(nextAction(job0, { ...ruled, status: 2n }, 60n), null, "disputed: wait for the owner");
  assert.equal(nextAction(job0, { ...ruled, status: 2n }, 500n), "expire");
  assert.equal(nextAction(job0, { ...ruled, status: 4n }, 60n), "settle", "overturned Refund: pay the seller");
  assert.equal(nextAction({ ...job0, delivered: true }, { ...ruled, status: 5n }, 1000n), "releaseAfterBackstop");
  assert.equal(nextAction(job0, { ...ruled, status: 5n }, 101n), "refundAfterDeadline");
});

test("guards: mainnet deployers, other chains, remote writes", async () => {
  for (const address of FORBIDDEN_KEYS) assert.throws(() => guardKey({ address }), /mainnet deployer/);
  const provider = (chainId) => ({ getNetwork: async () => ({ chainId: BigInt(chainId) }) });
  await assert.rejects(guardNetwork(provider(5042), "https://rpc.mainnet.arc.io"), /not allowed/);
  await assert.rejects(guardNetwork(provider(8453), "http://127.0.0.1:8545"), /not allowed/);
  await assert.rejects(guardNetwork(provider(31337), "https://example.com"), /not Arc testnet/);
  const saved = process.env.CONFIRM_TESTNET;
  delete process.env.CONFIRM_TESTNET;
  try {
    assert.equal((await guardNetwork(provider(5042002), "https://rpc.testnet.arc.network")).canWrite, false, "read only by default");
    await assert.rejects(guardNetwork(provider(5042002), "https://rpc.testnet.arc.network", { broadcast: true }), /CONFIRM_TESTNET/);
    process.env.CONFIRM_TESTNET = "arc-testnet";
    assert.equal((await guardNetwork(provider(5042002), "https://rpc.testnet.arc.network", { broadcast: true })).canWrite, true);
    assert.equal((await guardNetwork(provider(5042002), "https://rpc.testnet.arc.network")).canWrite, false, "the env alone does not write");
  } finally {
    if (saved === undefined) delete process.env.CONFIRM_TESTNET;
    else process.env.CONFIRM_TESTNET = saved;
  }
  assert.equal((await guardNetwork(provider(31337), "http://127.0.0.1:8545")).canWrite, false, "local is read only without --broadcast too");
  assert.equal((await guardNetwork(provider(31337), "http://127.0.0.1:8545", { broadcast: true })).canWrite, true);
  assert.ok(isLocalRpc("http://localhost:8545"));
  assert.ok(!isLocalRpc("https://rpc.testnet.arc.network"));
});
