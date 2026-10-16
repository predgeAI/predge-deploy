// Runs `deploy.mjs --chain <c> --fork` for every chain (or the ones given) and writes a summary.
// Each run: anvil --fork-url <live rpc>, full deploy at nonces 0..5, 23 read-only checks, 13-tx honest path.
import { spawnSync } from "node:child_process";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { CHAINS } from "../lib/chains.mjs";

const ROOT = new URL("../", import.meta.url).pathname;
const only = process.argv.slice(2);
const names = only.length ? only : Object.keys(CHAINS);
const summary = {};
for (const name of names) {
  const t = Date.now();
  const r = spawnSync(process.execPath, [`${ROOT}deploy.mjs`, "--chain", name, "--fork"], { encoding: "utf8", timeout: 600000 });
  const out = (r.stdout || "") + (r.stderr || "");
  const ok = r.status === 0;
  const f = `${ROOT}deployments/fork/${name}.json`;
  const rec = ok && existsSync(f) ? JSON.parse(readFileSync(f, "utf8")) : null;
  summary[name] = ok
    ? { ok, seconds: Math.round((Date.now() - t) / 1000), gasUsed: rec.totals.gasUsed, cost: rec.totals.cost, native: rec.totals.native, e2eTxs: rec.e2e?.length ?? 0, smokeChecks: rec.smoke.length }
    : { ok, error: (out.match(/FAILED: .*/) || [out.slice(-300)])[0] };
  console.log(`${name.padEnd(10)} ${ok ? "PASS" : "FAIL"} ${ok ? `${summary[name].gasUsed} gas, ${summary[name].cost} ${summary[name].native}` : summary[name].error}`);
}
const file = `${ROOT}deployments/fork/SUMMARY.json`;
const prev = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
writeFileSync(file, JSON.stringify({ ...prev, ...summary }, null, 2) + "\n");
