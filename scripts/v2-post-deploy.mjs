#!/usr/bin/env node
// After the founder has broadcast the v2.1 set (config/set.v2.json, nonces 6..11) on Arc and Base:
//   node scripts/v2-post-deploy.mjs [--chains arc,base] [--from-ref 849d1ff] [--no-verify] [--check]
//
//   1. keeps the 20.10 records: deployments/v2/<chain>.v2-0.json and deployments/v2/verify/<Name>.v2-0.json, restored
//      from git (`--from-ref`, default 849d1ff = the commit that recorded v2.0), because `deploy.mjs --broadcast` has
//      overwritten deployments/v2/<chain>.json and verify/*.json in place; marks them deprecated;
//   2. links the new record to the old one (`supersedes`);
//   3. retries Sourcify (then Etherscan/Blockscout, as deploy.mjs does) for any contract the broadcast left unverified;
//   4. rewrites the README "v2" deployments section: the v2.1 table as current, the v2.0 addresses marked DEPRECATED.
// Idempotent. Sends no transaction and reads no key. `--check` only validates and prints what it would do.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { chainConfig, SET_V2 } from "../lib/chains.mjs";
import { resolvePlan } from "../lib/plan.mjs";
import { chainParams } from "../lib/v2.mjs";
import { verifyStep } from "../lib/verify.mjs";

const ROOT = new URL("../", import.meta.url).pathname;
const argv = process.argv.slice(2);
const opt = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };
const flag = (f) => argv.includes(f);
const CHAINS = opt("--chains", "arc,base").split(",");
const REF = opt("--from-ref", "849d1ff");
const OLD_VERSION = "2026-10-20-v2";
const CHECK = flag("--check");
const json = (o) => JSON.stringify(o, null, 2) + "\n";
const git = (...a) => execFileSync("git", ["-C", ROOT, ...a], { encoding: "utf8" });
const write = (rel, content) => { if (CHECK) console.log(`  would write ${rel}`); else writeFileSync(`${ROOT}${rel}`, content); };
const fail = (m) => { console.error(`v2-post-deploy: ${m}`); process.exit(1); };

const records = {};
for (const c of CHAINS) {
  const path = `deployments/v2/${c}.json`;
  if (!existsSync(`${ROOT}${path}`)) fail(`${path} missing: broadcast ${c} first`);
  const r = JSON.parse(readFileSync(`${ROOT}${path}`, "utf8"));
  if (r.setVersion !== SET_V2.version) fail(`${path} has setVersion ${r.setVersion}, expected ${SET_V2.version}: was ${c} broadcast with the v2.1 set?`);
  const names = SET_V2.plan.map((s) => s.name);
  for (const [i, n] of names.entries()) {
    const k = r.contracts[n];
    if (!k) fail(`${path}: ${n} missing`);
    if (k.nonce !== (SET_V2.nonceBase ?? 0) + i) fail(`${path}: ${n} at nonce ${k.nonce}, expected ${(SET_V2.nonceBase ?? 0) + i}`);
  }
  records[c] = r;
}
const addrs = (r) => SET_V2.plan.map((s) => r.contracts[s.name].address);
const first = addrs(records[CHAINS[0]]);
for (const c of CHAINS) if (addrs(records[c]).join() !== first.join()) fail(`addresses differ between ${CHAINS[0]} and ${c}`);

// 1-2. archive the v2.0 records from git and link them
const old = {};
for (const c of CHAINS) {
  const arch = `deployments/v2/${c}.v2-0.json`;
  let o;
  if (existsSync(`${ROOT}${arch}`)) o = JSON.parse(readFileSync(`${ROOT}${arch}`, "utf8"));
  else {
    o = JSON.parse(git("show", `${REF}:deployments/v2/${c}.json`));
    if (o.setVersion !== OLD_VERSION) fail(`${REF}:deployments/v2/${c}.json is ${o.setVersion}, not ${OLD_VERSION}`);
  }
  o.deprecated = { by: SET_V2.version, record: `${c}.json`, reason: "Olympix BugPoCer scan of c47ed42 (23.10.2026): confirmed findings, fixed in v2.1. Not upgradeable, so the v2.0 instances stay on chain; do not use them." };
  write(arch, json(o));
  old[c] = o;
  records[c].supersedes = { setVersion: OLD_VERSION, record: `${c}.v2-0.json`, addresses: Object.fromEntries(Object.entries(o.contracts).map(([k, v]) => [k, v.address])) };
}
for (const f of git("ls-tree", "--name-only", `${REF}`, "deployments/v2/verify/").split("\n").filter(Boolean)) {
  const to = f.replace(/\.json$/, ".v2-0.json");
  if (!existsSync(`${ROOT}${to}`)) write(to, git("show", `${REF}:${f}`));
}

// 3. retry verification for anything left unverified
if (!flag("--no-verify")) {
  for (const c of CHAINS) {
    const r = records[c];
    const chain = chainConfig(c);
    const plan = resolvePlan(r.deployer, { owner: r.owner, operator: r.operator, ...chainParams(c) }, SET_V2);
    for (const s of plan) {
      const k = r.contracts[s.name];
      if (k.address !== s.address) fail(`${c}: ${s.name} recorded at ${k.address}, plan says ${s.address}`);
      if (k.verified?.ok) continue;
      if (CHECK) { console.log(`  would verify ${c} ${s.name}`); continue; }
      k.verified = await verifyStep(chain, s, k.txHash);
      console.log(`  verify ${c} ${s.name}: ${k.verified.ok ? "OK via " + k.verified.via : "TODO " + JSON.stringify(k.verified).slice(0, 200)}`);
    }
  }
}
for (const c of CHAINS) write(`deployments/v2/${c}.json`, json(records[c]));

// 4. README
const EXPL = { arc: (a) => `[Arc](https://explorer.arc.io/address/${a})`, base: (a) => `[Base](https://basescan.org/address/${a})` };
const label = (n) => (n === "MockRefundProtocolV2" ? "MockRefundProtocolV2 (demo refund protocol)" : n);
const row = (n, a) => `| ${label(n)} | \`${a}\` | [Sourcify](https://sourcify.dev/#/lookup/${a}) | ${CHAINS.map((c) => (EXPL[c] ?? (() => c))(a)).join(", ")} |`;
const r0 = records[CHAINS[0]], o0 = old[CHAINS[0]];
const OWNER_NOTE = (() => { try { return JSON.parse(readFileSync(`${ROOT}config/v2.config.json`, "utf8"))._owner_note ?? ""; } catch { return ""; } })().replace(/^[0-9.]+:\s*/, "");
const allVerified = CHAINS.every((c) => Object.values(records[c].contracts).every((k) => k.verified?.ok));
const day = (iso) => iso.slice(0, 10);
const section = `### v2 (current, v2.1): Arc (5042) and Base (8453)

Deployed ${[...new Set(CHAINS.map((c) => day(records[c].deployedAt)))].join(" / ")} from set \`${SET_V2.version}\` (deployer nonces ${SET_V2.nonceBase}..${SET_V2.nonceBase + SET_V2.plan.length - 1}). The same six addresses on both chains. ${allVerified ? "All six are verified on Sourcify." : "**Verification incomplete: see the `verified` fields in the records.**"} Receipts: ${CHAINS.map((c) => `[\`deployments/v2/${c}.json\`](deployments/v2/${c}.json)`).join(", ")}.

| Contract | Address (${CHAINS.map((c) => c[0].toUpperCase() + c.slice(1)).join(" and ")}) | Sourcify | Explorer |
|---|---|---|---|
${SET_V2.plan.map((s) => row(s.name, r0.contracts[s.name].address)).join("\n")}

- **Owner:** \`${r0.owner}\`${OWNER_NOTE ? ` (${OWNER_NOTE})` : ""}. **Operator** (hot ops key, rotatable by the owner): \`${r0.operator}\`.
- **Bond floor:** minimal (bps = 0), per-chain floor from \`config/v2.chains.json\`. Since v2.1 the validator bond backs liveness only: \`recordScore\` refuses any verdict that contradicts the on-chain evidence (pass needs the output bytes hashed on-chain and equal to the client-committed \`expected\`; fail needs the opposite), so a false verdict cannot be recorded at any bond size and there is no challenge window.
- **Status:** v2.1 contains the fixes for the Olympix BugPoCer scan of \`c47ed42\` (23 Oct 2026) and the option (a) verdict check. The signed verdict API (\`api.predge.io\`) is unchanged and remains the product.

### v2.0 (DEPRECATED, 20-21 Oct 2026): do not use

The first v2 set (\`${OLD_VERSION}\`, commit \`c47ed42\`) is still on chain at the addresses below, because the contracts are not upgradeable. It is affected by the confirmed Olympix findings and held no funds when it was superseded. Nothing in Predge points at it. Records: ${CHAINS.map((c) => `[\`deployments/v2/${c}.v2-0.json\`](deployments/v2/${c}.v2-0.json)`).join(", ")}.

| Contract | Deprecated address (${CHAINS.map((c) => c[0].toUpperCase() + c.slice(1)).join(" and ")}) |
|---|---|
${SET_V2.plan.map((s) => `| ${s.name} | ~~\`${o0.contracts[s.name].address}\`~~ |`).join("\n")}

`;
const readme = readFileSync(`${ROOT}README.md`, "utf8");
const start = readme.search(/^### v2 \(current/m), end = readme.indexOf("### v1 (legacy)");
if (start < 0 || end < start) fail("README: could not find the v2 deployments section");
write("README.md", readme.slice(0, start) + section + readme.slice(end));
console.log(`${CHECK ? "check ok" : "done"}: ${CHAINS.join(", ")} -> ${first[0]}.. (v2.1); v2.0 archived from ${REF}`);
