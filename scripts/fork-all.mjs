// Runs `deploy.mjs --chain <c> --fork` for every chain (or the ones given) and writes a summary.
// Each run: anvil --fork-url <live rpc>, full deploy at nonces 0..5, 23 read-only checks, 13-tx honest path.
import { spawnSync } from "node:child_process";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { CHAINS } from "../lib/chains.mjs";

const ROOT = new URL("../", import.meta.url).pathname;
// usage: node scripts/fork-all.mjs [--set v2] [--no-e2e] [chain ...]
const args = process.argv.slice(2);
const V2 = args.includes("--set") && args[args.indexOf("--set") + 1] === "v2";
const extra = [...(V2 ? ["--set", "v2"] : []), ...(args.includes("--no-e2e") ? ["--no-e2e"] : [])];
const DIR = V2 ? "deployments/fork-v2" : "deployments/fork";
const only = args.filter((a, i) => !a.startsWith("--") && args[i - 1] !== "--set");
const names = only.length ? only : Object.keys(CHAINS);
const summary = {};
for (const name of names) {
  const t = Date.now();
  const r = spawnSync(process.execPath, [`${ROOT}deploy.mjs`, "--chain", name, "--fork", ...extra], { encoding: "utf8", timeout: 600000 });
  const out = (r.stdout || "") + (r.stderr || "");
  const ok = r.status === 0;
  const f = `${ROOT}${DIR}/${name}.json`;
  const rec = ok && existsSync(f) ? JSON.parse(readFileSync(f, "utf8")) : null;
  summary[name] = ok
    ? { ok, seconds: Math.round((Date.now() - t) / 1000), gasUsed: rec.totals.gasUsed, cost: rec.totals.cost, native: rec.totals.native, e2eTxs: rec.e2e?.length ?? 0, smokeChecks: rec.smoke.length }
    : { ok, error: (out.match(/FAILED: .*/) || [out.slice(-300)])[0] };
  console.log(`${name.padEnd(10)} ${ok ? "PASS" : "FAIL"} ${ok ? `${summary[name].gasUsed} gas, ${summary[name].cost} ${summary[name].native}` : summary[name].error}`);
}
const file = `${ROOT}${DIR}/SUMMARY.json`;
const prev = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
writeFileSync(file, JSON.stringify({ ...prev, ...summary }, null, 2) + "\n");
