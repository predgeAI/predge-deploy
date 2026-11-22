// Deadline helper for the Rootstock PoC pair (AgentJobV2 + PredgeNoObjectionEvaluator).
// Pure functions + one on-chain reader. Every deadline is returned in UTC and in the caller's local time zone.
//
//   import { readJobDeadlines, closingSoon } from "./sdk/deadlines.mjs";
//   const d = await readJobDeadlines({ provider, job, evaluator, jobId, timeZone: "America/Bogota" });
//   const events = closingSoon(d);   // [] or [{ type: "closing_soon", deadline: "objection", window: "48h", ... }]

export const STATE = ["None", "Open", "Submitted", "Completed", "Rejected", "Expired"];
export const THRESHOLDS = [{ label: "48h", seconds: 48 * 3600 }, { label: "24h", seconds: 24 * 3600 }];

function fmt(ts, timeZone) {
  const d = new Date(ts * 1000);
  const local = new Intl.DateTimeFormat("en-GB", { timeZone, year: "numeric", month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZoneName: "short" }).format(d);
  return { unix: ts, utc: d.toISOString().replace(".000Z", "Z"), local, timeZone };
}

/**
 * Compute every deadline that matters for one job.
 * @param {object} p
 * @param {object} p.job        AgentJobV2.Job fields: state (number|bigint), expiredAt, submittedAt (unix seconds)
 * @param {number} p.objectionPeriod   evaluator.objectionPeriod() in seconds
 * @param {number} p.evaluationWindow  evaluator.evaluationWindow() in seconds
 * @param {{hash:string, at:number, resolved:boolean}} [p.objection]
 * @param {number} [p.now]      unix seconds (default: Date.now())
 * @param {string} [p.timeZone] IANA zone for the local column (default: system zone)
 */
export function computeDeadlines({ job, objectionPeriod, evaluationWindow, objection, now, timeZone }) {
  now = now ?? Math.floor(Date.now() / 1000);
  timeZone = timeZone ?? Intl.DateTimeFormat().resolvedOptions().timeZone;
  const state = STATE[Number(job.state)] ?? `Unknown(${job.state})`;
  const expiredAt = Number(job.expiredAt), submittedAt = Number(job.submittedAt);
  const objected = !!objection && objection.hash && !/^0x0+$/.test(objection.hash);
  const out = [];
  const add = (key, who, what, ts, active) => {
    const left = ts - now;
    out.push({ key, who, what, ...fmt(ts, timeZone), secondsLeft: left, passed: left <= 0, active });
  };
  if (state === "Open") {
    add("submit", "contractor", "submit the completion package before this time, or the client can reclaim the escrow", expiredAt, true);
  }
  if (state === "Submitted") {
    const objEnd = submittedAt + objectionPeriod, evalEnd = submittedAt + evaluationWindow;
    if (!objected) {
      add("objection", "client", "last moment to file a written objection; after it anyone can release the payment to the contractor", objEnd, true);
      add("releaseOnSilence", "anyone", "from this time the payment can be released to the contractor (no objection filed)", objEnd, false);
    } else if (!objection.resolved) {
      add("reviewerDecision", "reviewer", "objection filed: the reviewer must decide before this time, otherwise the client is refunded", evalEnd, true);
    }
    add("refundFallback", "anyone", "if nothing was decided by this time, the client can claim a refund", evalEnd, false);
  }
  return { state, objected: !!objected, now: fmt(now, timeZone), deadlines: out };
}

/**
 * "Closing soon" events: one per active deadline per threshold crossed (48h, 24h), plus "passed".
 * Pass `alreadySent` (Set of event ids) to get only new ones; ids are stable: `${jobId}:${key}:${window}`.
 */
export function closingSoon(d, { jobId = "?", thresholds = THRESHOLDS, alreadySent = new Set() } = {}) {
  const ev = [];
  for (const x of d.deadlines.filter((x) => x.active)) {
    let window = null;
    if (x.passed) window = "passed";
    else for (const t of [...thresholds].sort((a, b) => a.seconds - b.seconds)) if (x.secondsLeft <= t.seconds) { window = t.label; break; }
    if (!window) continue;
    const id = `${jobId}:${x.key}:${window}`;
    if (alreadySent.has(id)) continue;
    ev.push({ id, type: window === "passed" ? "deadline_passed" : "closing_soon", jobId: String(jobId), deadline: x.key, window, who: x.who, what: x.what,
      utc: x.utc, local: x.local, timeZone: x.timeZone, hoursLeft: Math.max(0, Math.round((x.secondsLeft / 3600) * 10) / 10) });
  }
  return ev;
}

/** Read one job from chain and compute its deadlines. `job`/`evaluator` are ethers Contracts. */
export async function readJobDeadlines({ job, evaluator, jobId, now, timeZone }) {
  const [j, period, window, o] = await Promise.all([job.getJob(jobId), evaluator.objectionPeriod(), evaluator.evaluationWindow(), evaluator.objectionOf(jobId)]);
  return computeDeadlines({ job: { state: j.state, expiredAt: j.expiredAt, submittedAt: j.submittedAt }, objectionPeriod: Number(period), evaluationWindow: Number(window),
    objection: { hash: o.hash, at: Number(o.at), resolved: o.resolved }, now, timeZone });
}
