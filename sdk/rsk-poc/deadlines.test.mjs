import test from "node:test";
import assert from "node:assert/strict";
import { computeDeadlines, closingSoon } from "./deadlines.mjs";
const H = 3600, D = 86400, sub = 1_763_678_618; // 2025-11-20T22:43:38Z-ish anchor
const base = { job: { state: 2, expiredAt: sub + 2 * D, submittedAt: sub }, objectionPeriod: 10 * D, evaluationWindow: 24 * D, timeZone: "America/Bogota" };
const zero = { hash: "0x" + "0".repeat(64), at: 0, resolved: false };

test("submitted, no objection: objection deadline active, UTC + local", () => {
  const d = computeDeadlines({ ...base, objection: zero, now: sub + D });
  const o = d.deadlines.find((x) => x.key === "objection");
  assert.equal(o.unix, sub + 10 * D); assert.ok(o.utc.endsWith("Z")); assert.match(o.local, /GMT-5|COT/); assert.equal(o.active, true);
  assert.deepEqual(closingSoon(d, { jobId: 1 }), []);
});
test("48h then 24h then passed, each once", () => {
  const sent = new Set();
  const at = (t) => closingSoon(computeDeadlines({ ...base, objection: zero, now: t }), { jobId: 1, alreadySent: sent });
  const e48 = at(sub + 10 * D - 47 * H); assert.equal(e48.length, 1); assert.equal(e48[0].window, "48h"); e48.forEach((e) => sent.add(e.id));
  assert.equal(at(sub + 10 * D - 30 * H).length, 0);
  const e24 = at(sub + 10 * D - 23 * H); assert.equal(e24[0].window, "24h"); e24.forEach((e) => sent.add(e.id));
  const ep = at(sub + 10 * D + 1); assert.equal(ep[0].type, "deadline_passed");
});
test("objection filed: reviewer deadline replaces objection deadline", () => {
  const d = computeDeadlines({ ...base, objection: { hash: "0x" + "1".repeat(64), at: sub + D, resolved: false }, now: sub + 23 * D });
  assert.equal(d.deadlines.some((x) => x.key === "objection"), false);
  const ev = closingSoon(d, { jobId: 2 }); assert.equal(ev[0].deadline, "reviewerDecision"); assert.equal(ev[0].window, "24h");
});
test("open job: submit deadline for contractor", () => {
  const d = computeDeadlines({ ...base, job: { state: 1, expiredAt: sub + 2 * D, submittedAt: 0 }, now: sub + D + 1 });
  assert.equal(closingSoon(d, { jobId: 3 })[0].who, "contractor");
});
test("completed job: nothing to watch", () => {
  assert.equal(computeDeadlines({ ...base, job: { state: 3, expiredAt: 0, submittedAt: sub } }).deadlines.length, 0);
});
