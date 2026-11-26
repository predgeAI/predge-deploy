// Watches PoC jobs on Rootstock testnet and emits "closing soon" events (48h, 24h, passed), once each.
//   node scripts/deadline-watch.mjs --jobs 1,2 [--tz America/Bogota] [--webhook https://...] [--loop 900]
// Output: one JSON line per event on stdout (+ POST to --webhook if given). Read-only: no keys, no transactions.
import { JsonRpcProvider, Contract } from "ethers";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { readJobDeadlines, closingSoon } from "../../sdk/rsk-poc/deadlines.mjs";

const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const JOBS = arg("jobs", "1").split(",").map((s) => s.trim());
const TZ = arg("tz", Intl.DateTimeFormat().resolvedOptions().timeZone), HOOK = arg("webhook"), LOOP = Number(arg("loop", 0));
const STATE_FILE = arg("state", "deadline-watch.sent.json");
const RPC = "https://public-node.testnet.rsk.co";
const JOB_ADDR = "0x5eAe41E4a082e6F5fDda067535757927c2716844", EV_ADDR = "0xc1e3259a417FD06781941cA973dB6e58274DA683";
const provider = new JsonRpcProvider(RPC, 31, { staticNetwork: true });
const job = new Contract(JOB_ADDR, ["function getJob(uint256) view returns (tuple(address client,address provider,address evaluator,uint256 escrow,uint64 expiredAt,uint64 submittedAt,uint8 state,bool hashedOnChain,bytes32 specHash,bytes32 deliverable,bytes32 reason))"], provider);
const evaluator = new Contract(EV_ADDR, ["function objectionPeriod() view returns (uint64)", "function evaluationWindow() view returns (uint64)",
  "function objectionOf(uint256) view returns (tuple(bytes32 hash,uint64 at,bool resolved))"], provider);
const sent = new Set(existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : []);

async function tick() {
  const now = (await provider.getBlock("latest")).timestamp; // chain time, the same clock the contracts use
  for (const jobId of JOBS) {
    const d = await readJobDeadlines({ job, evaluator, jobId, now, timeZone: TZ });
    if (process.argv.includes("--show")) console.error(JSON.stringify({ jobId, state: d.state, objected: d.objected, deadlines: d.deadlines.map(({ key, who, utc, local, secondsLeft }) => ({ key, who, utc, local, hoursLeft: +(secondsLeft / 3600).toFixed(1) })) }, null, 1));
    for (const e of closingSoon(d, { jobId, alreadySent: sent })) {
      console.log(JSON.stringify(e));
      if (HOOK) await fetch(HOOK, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(e) }).catch((err) => console.error("webhook", err.message));
      sent.add(e.id);
    }
  }
  writeFileSync(STATE_FILE, JSON.stringify([...sent], null, 1) + "\n");
}
await tick();
if (LOOP > 0) setInterval(() => tick().catch((e) => console.error(e.message)), LOOP * 1000);
