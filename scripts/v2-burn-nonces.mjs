#!/usr/bin/env node
// Brings a FRESH v2 deployer up to the set's nonceBase on a new chain, so the v2.1 set lands at the same
// addresses as on Arc and Base (where nonces 0..5 were used by the 20.10 v2.0 set).
//
//   node scripts/v2-burn-nonces.mjs --chain <name>                                   dry run: nonce, balance, cost. Sends nothing.
//   CONFIRM_MAINNET=<name> node scripts/v2-burn-nonces.mjs --chain <name> --broadcast --key-file ~/.predge-deployer-v2/deployer.json
//
// Each burned nonce is a 0-value transaction from the deployer to itself (no funds leave the address; only gas is paid).
// Refuses: the v1 key, a key that is not the configured v2 deployer, a nonce already past nonceBase, or any code
// already present at a planned v2.1 address.
import { formatEther } from "ethers";
import { chainConfig, pickRpc, providerFor, withRetry, waitReceipt, SET_V2 } from "../lib/chains.mjs";
import { loadDeployer } from "../lib/key.mjs";
import { resolvePlan } from "../lib/plan.mjs";
import { realRoles, chainParams, v2KeyFile } from "../lib/v2.mjs";

const argv = process.argv.slice(2);
const opt = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined; };
const name = opt("--chain");
if (!name) { console.error("usage: node scripts/v2-burn-nonces.mjs --chain <name> [--broadcast --key-file <v2 deployer json>]"); process.exit(2); }
const broadcast = argv.includes("--broadcast");
const chain = chainConfig(name);
const target = SET_V2.nonceBase ?? 0;

const url = await pickRpc(chain, opt("--rpc"));
const p = providerFor(url, chain.chainId);
const roles = realRoles();
const plan = resolvePlan(roles.deployer, { owner: roles.owner, operator: roles.operator, ...chainParams(chain.name) }, SET_V2);
for (const s of plan) if ((await p.getCode(s.address)).length > 2) { console.error(`code already at ${s.address} (${s.name}); stop`); process.exit(1); }

const [bal, nonce, fee] = await Promise.all([p.getBalance(roles.deployer), p.getTransactionCount(roles.deployer, "pending"), p.getFeeData()]);
const price = fee.gasPrice ?? fee.maxFeePerGas;
console.log(`${chain.name}: deployer ${roles.deployer} nonce ${nonce}, target ${target}, balance ${formatEther(bal)} ${chain.native}`);
if (nonce > target) { console.error(`nonce ${nonce} is already past ${target}: same-address deploy impossible here`); process.exit(1); }
const n = target - nonce;
console.log(`${n} self-transaction(s) needed, ~${formatEther(21000n * BigInt(n) * price)} ${chain.native} at ${price} wei`);
if (!broadcast || n === 0) { console.log(broadcast ? "nothing to do" : "dry run only. Nothing sent."); process.exit(0); }
if (process.env.CONFIRM_MAINNET !== chain.name) { console.error(`set CONFIRM_MAINNET=${chain.name}`); process.exit(3); }

const w = loadDeployer(p, v2KeyFile(opt("--key-file")));
if (w.address !== roles.deployer) { console.error(`key ${w.address} != config deployer ${roles.deployer}`); process.exit(1); }
for (let i = nonce; i < target; i++) {
  // Load-balanced RPCs can lag a block behind our own last receipt: a LOWER nonce is waited out, a HIGHER one is fatal.
  let cur = await withRetry("nonce", () => p.getTransactionCount(w.address, "pending"));
  for (let k = 0; cur < i && k < 40; k++) {
    await new Promise((r) => setTimeout(r, 1500));
    cur = await withRetry("nonce", () => p.getTransactionCount(w.address, "pending"));
  }
  if (cur !== i) { console.error(`expected nonce ${i}, chain says ${cur}; stop`); process.exit(1); }
  const est = await withRetry("estimateGas", () => p.estimateGas({ from: w.address, to: w.address, value: 0n }));
  const tx = await w.populateTransaction({ to: w.address, value: 0n, nonce: i, gasLimit: (est * 130n) / 100n });
  const raw = await w.signTransaction(tx);
  const sent = await withRetry(`send nonce ${i}`, () => p.broadcastTransaction(raw));
  const r = await waitReceipt(p, sent.hash);
  if (r.status !== 1) { console.error(`self-tx at nonce ${i} failed: ${sent.hash}`); process.exit(1); }
  console.log(`  nonce ${i} burned  gas ${r.gasUsed}  tx ${sent.hash}`);
}
const after = await p.getTransactionCount(w.address, "latest");
console.log(`done: nonce ${after}, balance ${formatEther(await p.getBalance(w.address))} ${chain.native}`);
process.exit(after === target ? 0 : 1);
