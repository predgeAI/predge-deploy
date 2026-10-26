#!/usr/bin/env node
// predge-deploy: one command, the full Predge set, same bytecode and same addresses on every EVM chain.
//
//   node deploy.mjs --chain base                 dry run on the live chain: plan, addresses, nonce/balance checks, gas estimate. Sends nothing.
//   node deploy.mjs --chain base --fork          deploy + smoke + end-to-end on a local `anvil --fork-url` of the chain. Sends nothing to the chain.
//   CONFIRM_MAINNET=base node deploy.mjs --chain base --broadcast
//                                                the real thing: deploy, verify source, read-only smoke, deployments/base.json.
// Options: --rpc <url> (override), --no-verify, --no-e2e (fork), --keep-anvil (fork)
//
//   --set v2   the v2 contract set (contracts/v2, config/set.v2.json). Roles (deployer / owner Safe / operator) come from
//              config/v2.config.json and must be filled in by the owner; --fork uses throwaway anvil accounts and also runs
//              the v1 attack sequences, which must revert. A real v2 --broadcast needs --key-file <new v2 deployer json>.
//              v2 NEVER reads ~/.predge-deployer. Outputs go to deployments/v2/ and deployments/fork-v2/.
import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync, existsSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import { formatEther, Wallet } from "ethers";
import { chainConfig, pickRpc, providerFor, withRetry, rawRpc, waitReceipt, SET, SET_V2 } from "./lib/chains.mjs";
import { loadDeployer } from "./lib/key.mjs";
import { resolvePlan } from "./lib/plan.mjs";
import { maskImmutables, SOLC_VERSION, SETTINGS } from "./lib/compile.mjs";
import { readOnly, e2e } from "./lib/smoke.mjs";
import { readOnlyV2, e2eV2 } from "./lib/smoke-v2.mjs";
import { realRoles, forkRoles, chainParams, anvilWallets, v2KeyFile } from "./lib/v2.mjs";
import { verifyStep } from "./lib/verify.mjs";
import { l1FeeWei } from "./lib/fees.mjs";

const argv = process.argv.slice(2);
const flag = (f) => argv.includes(f);
const opt = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined; };
const ROOT = new URL("./", import.meta.url).pathname;
const V2 = opt("--set") === "v2";
if (opt("--set") && !V2 && opt("--set") !== "v1") { console.error(`unknown --set ${opt("--set")} (v1 | v2)`); process.exit(2); }
const SETUSED = V2 ? SET_V2 : SET;
const OUT = V2 ? "deployments/v2" : "deployments";
const OUTFORK = V2 ? "deployments/fork-v2" : "deployments/fork";
const ANVIL = process.env.ANVIL_BIN || (existsSync(`${process.env.HOME}/.foundry/bin/anvil`) ? `${process.env.HOME}/.foundry/bin/anvil` : "anvil");
const ERC8004 = {
  IdentityRegistry: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
  ReputationRegistry: "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63",
  ValidationRegistry: "0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58",
};

function freePort() {
  return new Promise((res) => { const s = createServer(); s.listen(0, () => { const p = s.address().port; s.close(() => res(p)); }); });
}

async function startAnvil(forkUrl, chainId) {
  const port = await freePort();
  const child = spawn(ANVIL, ["--fork-url", forkUrl, "--port", String(port), "--chain-id", String(chainId), "--silent", "--retries", "10", "--timeout", "60000"], { stdio: ["ignore", "ignore", "pipe"] });
  let err = ""; child.stderr.on("data", (d) => (err += d));
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 120; i++) {
    await new Promise((r) => setTimeout(r, 500));
    if (child.exitCode !== null) throw new Error(`anvil exited: ${err.slice(0, 400)}`);
    try { await rawRpc(url, "eth_chainId", [], 2000); return { url, child }; } catch {}
  }
  child.kill(); throw new Error("anvil did not start");
}

async function registries(provider) {
  const out = {};
  for (const [k, a] of Object.entries(ERC8004)) {
    const code = await provider.getCode(a).catch(() => "0x");
    let version = null;
    if (code.length > 2) {
      try { version = (await provider.call({ to: a, data: "0x0d8e6e2c" }).then((r) => new TextDecoder().decode(Buffer.from(r.slice(130), "hex")).replace(/\0/g, "").trim())) || null; } catch {}
    }
    out[k] = code.length > 2 ? { address: a, version } : null;
  }
  return out;
}

/** Sends the plan from `wallet`, step i at nonce i, idempotent and refusing anything that would shift addresses. */
async function deploySet(provider, wallet, plan, { log, gasLimitPct = 125 }) {
  const results = [];
  for (const step of plan) {
    const code = await withRetry("getCode", () => provider.getCode(step.address));
    const c = step.compiled;
    if (code.length > 2) {
      if (maskImmutables(code, c.immutableReferences) !== maskImmutables(c.deployedBytecode, c.immutableReferences))
        throw new Error(`${step.address} (nonce ${step.nonce}) holds code that is NOT ${step.name}. Stop.`);
      log(`  = ${step.name.padEnd(22)} ${step.address} already deployed, skipping`);
      results.push({ ...pick(step), skipped: true });
      continue;
    }
    // Load-balanced RPCs (and forks) can lag a block behind our own last receipt: a LOWER nonce is
    // retried for a while; a HIGHER one means the key was used elsewhere and is fatal.
    let nonce = await withRetry("nonce", () => provider.getTransactionCount(wallet.address, "pending"));
    for (let i = 0; nonce < step.nonce && i < 40; i++) {
      await new Promise((r) => setTimeout(r, 1500));
      nonce = await withRetry("nonce", () => provider.getTransactionCount(wallet.address, "pending"));
    }
    if (nonce !== step.nonce)
      throw new Error(`deployer nonce is ${nonce} but ${step.name} must be created at nonce ${step.nonce} to land at ${step.address}. ` +
        `The key was used outside predge-deploy on this chain; same-address deploy is no longer possible here.`);
    const gas = await withRetry("estimateGas", () => provider.estimateGas({ from: wallet.address, data: step.initcode, nonce }));
    const populated = await wallet.populateTransaction({ data: step.initcode, nonce, gasLimit: (gas * BigInt(gasLimitPct)) / 100n });
    const rawTx = await wallet.signTransaction(populated);
    const tx = await withRetry(`send ${step.name}`, () => provider.broadcastTransaction(rawTx));
    const r = await waitReceipt(provider, tx.hash);
    if (r.status !== 1) throw new Error(`${step.name} deploy reverted: ${tx.hash}`);
    if (r.contractAddress !== step.address) throw new Error(`${step.name} landed at ${r.contractAddress}, expected ${step.address}`);
    log(`  + ${step.name.padEnd(22)} ${step.address} gas ${r.gasUsed} tx ${tx.hash}`);
    results.push({ ...pick(step), txHash: tx.hash, block: r.blockNumber, gasUsed: r.gasUsed.toString(), effectiveGasPrice: (r.gasPrice ?? 0n).toString(), rawTx });
  }
  return results;
}

function pick(step) {
  return { name: step.name, address: step.address, nonce: step.nonce, args: step.args.map(String), constructorArgs: step.constructorArgs, sourceSha256: step.compiled.sourceSha256, source: step.source };
}

const json = (o) => JSON.stringify(o, (k, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n";

async function main() {
  const name = opt("--chain");
  if (!name) { console.error("usage: node deploy.mjs --chain <name> [--fork | --broadcast]"); process.exit(2); }
  const chain = chainConfig(name);
  const mode = flag("--broadcast") ? "broadcast" : flag("--fork") ? "fork" : "dry-run";
  const T0 = Date.now(); const log = (...a) => console.log(`[${((Date.now() - T0) / 1000).toFixed(1)}s]`, ...a);
  log(`\n=== predge-deploy ${chain.name} (chainId ${chain.chainId}) mode=${mode} solc ${SOLC_VERSION} opt ${SETTINGS.optimizer.runs} evm ${SETTINGS.evmVersion} ===`);

  const liveUrl = await pickRpc(chain, opt("--rpc"));
  const live = providerFor(liveUrl, chain.chainId);
  // v1: the one deployer key. v2: roles from config (real runs) or anvil accounts (fork); a v2 key is only loaded to broadcast.
  const roles = V2 ? (mode === "fork" ? forkRoles() : realRoles()) : null;
  let deployer;
  if (V2) deployer = mode === "broadcast" ? loadDeployer(live, v2KeyFile(opt("--key-file"))) : { address: roles.deployer };
  else deployer = loadDeployer(live);
  if (V2 && mode === "broadcast" && deployer.address !== roles.deployer) throw new Error(`--key-file address ${deployer.address} != config deployer ${roles.deployer}`);
  const plan = V2
    ? resolvePlan(deployer.address, { owner: roles.owner, operator: roles.operator, ...chainParams(chain.name) }, SET_V2)
    : resolvePlan(deployer.address);
  log(`deployer ${deployer.address}  rpc ${liveUrl}${V2 ? `  (v2: owner ${roles.owner}, operator ${roles.operator})` : ""}`);
  for (const s of plan) log(`  nonce ${s.nonce}  ${s.name.padEnd(22)} -> ${s.address}`);

  if (mode === "broadcast") {
    if (process.env.CONFIRM_MAINNET !== chain.name) {
      console.error(`Refusing to broadcast: set CONFIRM_MAINNET=${chain.name} to deploy to ${chain.name} mainnet.`);
      process.exit(3);
    }
  }

  if (mode === "dry-run" || mode === "broadcast") {
    const [bal, nonce, fee] = await Promise.all([live.getBalance(deployer.address), live.getTransactionCount(deployer.address, "pending"), live.getFeeData()]);
    const price = fee.gasPrice ?? fee.maxFeePerGas;
    let gas = 0n;
    for (const s of plan) {
      const code = await live.getCode(s.address);
      if (code.length > 2) { log(`  ${s.name} already on chain`); continue; }
      const g = await withRetry("estimate", () => live.estimateGas({ from: deployer.address, data: s.initcode })).catch((e) => { throw new Error(`estimateGas ${s.name}: ${e.shortMessage || e.message}`); });
      gas += g;
    }
    const need = (gas * price * 150n) / 100n;
    log(`\nnonce ${nonce}, balance ${formatEther(bal)} ${chain.native}; estimated gas ${gas} @ ${price} wei = ${formatEther(gas * price)} ${chain.native} (fund >= ${formatEther(need)} incl. 50% buffer; L2 data fees: see funding table)`);
    const base = plan[0].nonce, done = nonce - base;
    if (done < 0 || done > plan.length) throw new Error(`deployer nonce ${nonce} on ${chain.name} is outside this set's nonces ${base}..${base + plan.length}: nonce desync.`);
    if (done > 0 && (await live.getCode(plan[done - 1].address)).length <= 2)
      throw new Error(`deployer nonce ${nonce} on ${chain.name} but the contract for nonce ${nonce - 1} is missing: nonce desync.`);
    if (mode === "dry-run") { log("dry run only. Nothing sent."); return; }
    if (bal < (gas * price)) { console.error(`Balance too low. Fund ${deployer.address} with >= ${formatEther(need)} ${chain.native} on ${chain.name}.`); process.exit(4); }

    const results = await deploySet(live, deployer, plan, { log, gasLimitPct: chain.gasLimitPct });
    const smoke = V2 ? await readOnlyV2(live, plan, roles) : await readOnly(live, plan, deployer.address);
    log(`smoke: ${smoke.length} checks passed`);
    const verification = {};
    mkdirSync(`${ROOT}${OUT}/verify`, { recursive: true });
    for (const s of plan) {
      writeFileSync(`${ROOT}${OUT}/verify/${s.name}.json`, json(s.compiled.input));
      const r = results.find((x) => x.name === s.name);
      verification[s.name] = flag("--no-verify") ? { ok: false, todo: "skipped (--no-verify)" } : await verifyStep(chain, s, r?.txHash);
      log(`  verify ${s.name}: ${verification[s.name].ok ? "OK via " + verification[s.name].via : "TODO " + JSON.stringify(verification[s.name].tried ?? verification[s.name].todo).slice(0, 200)}`);
    }
    const record = {
      chain: chain.name, chainId: chain.chainId, deployer: deployer.address, operator: V2 ? roles.operator : plan[0].args[0], ...(V2 ? { owner: roles.owner } : {}), setVersion: SETUSED.version,
      compiler: { solc: plan[0].compiled.compilerVersion, settings: { optimizer: SETTINGS.optimizer, evmVersion: SETTINGS.evmVersion } },
      deployedAt: new Date().toISOString(), explorer: chain.explorer,
      contracts: Object.fromEntries(results.map(({ rawTx, ...r }) => [r.name, { ...r, verified: verification[r.name] }])),
      erc8004: await registries(live), smoke, legacy: chain.legacy ?? null,
    };
    mkdirSync(`${ROOT}${OUT}`, { recursive: true });
    writeFileSync(`${ROOT}${OUT}/${chain.name}.json`, json(record));
    log(`wrote ${OUT}/${chain.name}.json`);
    return;
  }

  // ---- fork mode ----
  // Some public RPCs serve normal calls but not what anvil needs to fork; try the list in order.
  let started, lastErr;
  for (const u of opt("--rpc") ? [liveUrl] : [liveUrl, ...chain.rpc.filter((x) => x !== liveUrl)]) {
    try { started = { ...(await startAnvil(u, chain.chainId)), via: u }; break; } catch (e) { lastErr = e; log(`  anvil could not fork via ${u}: ${String(e.message).split("\n")[0].slice(0, 120)}`); }
  }
  if (!started) throw lastErr;
  const { url: forkUrl, child } = started;
  try {
    const fork = providerFor(forkUrl, chain.chainId);
    // v1 forks with the real deployer key (it is only ever funded on the fork). v2 NEVER does: anvil account 0.
    const anvil = V2 ? anvilWallets(fork) : null;
    const forkWallet = V2 ? anvil[0] : new Wallet(deployer.privateKey, fork);
    if (V2) for (const w of anvil) { await fork.send("anvil_setCode", [w.address, "0x"]); await fork.send("anvil_setNonce", [w.address, "0x0"]); await fork.send("anvil_setBalance", [w.address, "0x3635C9ADC5DEA00000"]); } // clean EOAs at nonce 0 (the public anvil keys are heavily used on mainnets), 1000 native, fork only
    if (V2 && plan[0].nonce > 0) await fork.send("anvil_setNonce", [anvil[0].address, "0x" + plan[0].nonce.toString(16)]); // the fork deployer starts where the real one does (set nonceBase)
    const startNonce = await fork.getTransactionCount(deployer.address);
    await fork.send("anvil_setBalance", [deployer.address, "0x56BC75E2D63100000"]); // 100 native, fork only
    const t0 = Date.now();
    const results = await deploySet(fork, forkWallet, plan, { log, gasLimitPct: chain.gasLimitPct });
    const smoke = V2 ? await readOnlyV2(fork, plan, roles) : await readOnly(fork, plan, deployer.address);
    log(`smoke: ${smoke.length} read-only checks passed`);
    let steps = null, attacks = null;
    if (!flag("--no-e2e") && V2) {
      const [, owner, op, client, worker, party] = anvil;
      const r = await e2eV2(fork, plan, { owner, op, client, worker, party }, async (s) => { await fork.send("evm_increaseTime", [s]); await fork.send("evm_mine", []); });
      steps = r.steps; attacks = r.attacks;
      log(`e2e: ${steps.length} honest-path txs passed; ${attacks.length} attack sequences blocked (H-01, H-02, H-03, M-03, Olympix 5.1.1/5.2.2, false pass/fail)`);
    } else if (!flag("--no-e2e")) {
      // Fresh throwaway keys, funded on the fork only (the well-known anvil test accounts carry
      // EIP-7702 delegations on several mainnets, so they are not clean EOAs on a fork).
      const signers = [0, 1, 2].map(() => Wallet.createRandom().connect(fork));
      for (const w of signers) await fork.send("anvil_setBalance", [w.address, "0x8AC7230489E80000"]);
      steps = await e2e(fork, plan, forkWallet, signers, async (s) => { await fork.send("evm_increaseTime", [s]); await fork.send("evm_mine", []); });
      log(`e2e: ${steps.length} honest-path txs passed (job, validator, bond, arbiter, settlement, reclaims after window)`);
    }
    // Price it with the LIVE chain's gas price and L2 data fee, so the funding table is real money.
    const fee = await live.getFeeData();
    const gasPrice = fee.gasPrice ?? fee.maxFeePerGas;
    let gasUsed = 0n, l1 = 0n; const l1how = new Set();
    for (const r of results) {
      if (r.skipped) continue;
      gasUsed += BigInt(r.gasUsed);
      const step = plan.find((s) => s.name === r.name);
      const f = await l1FeeWei(chain, liveUrl, { rawTx: r.rawTx, initcode: step.initcode, gasPrice });
      r.l1FeeWei = f.wei.toString(); l1 += f.wei; l1how.add(f.how);
    }
    const costWei = gasUsed * gasPrice + l1;
    const record = {
      chain: chain.name, chainId: chain.chainId, mode: "anvil-fork", forkedFrom: started.via, forkBlock: Number(await live.getBlockNumber()),
      at: new Date().toISOString(), seconds: Math.round((Date.now() - t0) / 1000), deployer: deployer.address, startNonce,
      contracts: Object.fromEntries(results.map(({ rawTx, ...r }) => [r.name, r])),
      totals: { gasUsed: gasUsed.toString(), liveGasPriceWei: gasPrice.toString(), l1FeeWei: l1.toString(), l1FeeMethod: [...l1how].join("; "), costWei: costWei.toString(), cost: formatEther(costWei), native: chain.native },
      smoke: smoke.map((c) => c.check), e2e: steps, ...(V2 ? { attacksBlocked: attacks, setVersion: SETUSED.version } : {}), erc8004: await registries(live),
    };
    mkdirSync(`${ROOT}${OUTFORK}`, { recursive: true });
    writeFileSync(`${ROOT}${OUTFORK}/${chain.name}.json`, json(record));
    log(`fork total: gas ${gasUsed} @ live ${gasPrice} wei + L1 ${formatEther(l1)} = ${formatEther(costWei)} ${chain.native}`);
    log(`wrote ${OUTFORK}/${chain.name}.json`);
  } finally {
    if (!flag("--keep-anvil")) child.kill();
  }
}

main().catch((e) => { console.error(`\nFAILED: ${e.shortMessage || e.message}`); if (process.env.DEBUG) console.error(e); process.exit(1); });
