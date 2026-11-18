#!/usr/bin/env node
// Arc testnet operations, one step at a time, because the challenge window is a real hour there.
// DEMO ONLY, UNAUDITED, TESTNET ONLY. Without --broadcast, nothing is sent.
//
//   keygen                              fresh testnet-only keys in ~/.predge-job-escrow/keys.json (mode 600)
//   status                              addresses, balances, deployment (read only)
//   fund                                move native USDC from the owner wallet to the other non-buyer roles
//   deploy [--min-bond 1]               escrow + fresh PredgeRefundArbiterV2, window 1 hour
//   start --scene release|refund        pay, call seller, file evidence, get verdict, relay it
//   relay --job N --verdict-id vrd_..   relay a stored verdict (or --verdict-file f.json)
//   keeper [--watch 60]                 settle whatever can move
//   dispute --job N --as seller|refundTo
//   resolve --job N --final refund|release
//   withdraw --as operator|seller|refundTo   collect a returned bond or a slashed bond
//
// Writing to Arc testnet needs --broadcast AND CONFIRM_TESTNET=arc-testnet. Pilot key: env PREDGE_KEY.
// --rpc <url> --usdc <mock> --api mock rehearses all of this on a plain local anvil.
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { Contract, ethers, parseUnits, Wallet } from "ethers";
import { fetchKeyRegistry, fetchVerdict } from "./lib/api.mjs";
import { ARC_TESTNET, attach, deployEscrowSet, fmtUsdc, guardNetwork, isLocalRpc, KEYS_FILE, loadKeys, RulingStatus } from "./lib/chain.mjs";
import { keeperPass } from "./lib/keeper.mjs";
import { planVerdict } from "./lib/relayer.mjs";
import { startMockApi } from "./lib/mock-api.mjs";
import { startSeller } from "./lib/seller.mjs";
import { askForVerdict, callSeller, fileDeliveryEvidence, jobSpec, payForJob, relay } from "./lib/scenario.mjs";
import { Direction, trustedKeysFromRegistry } from "./lib/verdict.mjs";

const args = process.argv.slice(2);
const command = args[0];
const opt = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const flag = (name) => args.includes(name);

const STATE_FILE = process.env.JOB_ESCROW_STATE || join(dirname(KEYS_FILE), "arc-testnet.json");
const PRICE = parseUnits(opt("--amount") ?? "10", 6);

// Native USDC each role should hold: 3 open 1 USDC bonds plus gas for the operator, gas for the rest.
const WANT = { operator: "4", refundTo: "0.2", seller: "0.5" };

function keygen() {
  if (existsSync(KEYS_FILE)) throw new Error(`${KEYS_FILE} already exists; not overwriting`);
  mkdirSync(dirname(KEYS_FILE), { recursive: true, mode: 0o700 });
  const out = {};
  for (const role of ["owner", "operator", "buyer", "refundTo", "seller"]) {
    const w = Wallet.createRandom();
    out[role] = { address: w.address, privateKey: w.privateKey };
  }
  writeFileSync(KEYS_FILE, JSON.stringify(out, null, 2), { mode: 0o600 });
  chmodSync(KEYS_FILE, 0o600);
  console.log(`Wrote ${KEYS_FILE}. Testnet only. Do not send real funds to these.`);
  for (const [role, v] of Object.entries(out)) console.log(`  ${role.padEnd(9)} ${v.address}`);
  console.log(`\nFaucet (faucet.circle.com, Arc Testnet, 20 USDC per request, 2 hours apart per address):\n  owner once, then buyer twice. Then: CONFIRM_TESTNET=arc-testnet node demo/job-escrow/cli.mjs fund --broadcast`);
}

const loadState = () => (existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : null);
const needState = () => loadState() ?? (() => { throw new Error(`no deployment in ${STATE_FILE}. Run: deploy --broadcast`); })();

async function world() {
  const rpcUrl = opt("--rpc") ?? ARC_TESTNET.rpc;
  const provider = new ethers.JsonRpcProvider(rpcUrl, undefined, { cacheTimeout: -1 });
  const guard = await guardNetwork(provider, rpcUrl, { broadcast: flag("--broadcast") });
  return { rpcUrl, provider, ...guard, wallets: loadKeys(provider) };
}

const link = (w, hash) => (w.local ? hash : `${ARC_TESTNET.explorer}/tx/${hash}`);

function requireWrite(w, what) {
  if (w.canWrite) return true;
  console.log(`DRY RUN: would ${what}. Nothing sent. To send: add --broadcast and set CONFIRM_TESTNET=arc-testnet.`);
  return false;
}

/** A real testnet job takes real verdicts. The stand-in is only for a local rehearsal. */
async function apiConfig(w) {
  if (opt("--api") === "mock") {
    if (!isLocalRpc(w.rpcUrl)) throw new Error("--api mock is for a local node only");
    const mock = await startMockApi();
    return { apiBase: mock.url, apiKey: "local-demo-key", close: mock.close };
  }
  return { apiBase: process.env.PREDGE_API_URL || "https://api.predge.io", apiKey: process.env.PREDGE_KEY, close: () => {} };
}

async function status() {
  const w = await world();
  const state = loadState();
  const fee = await w.provider.getFeeData();
  console.log(`chain ${w.chainId}, gas price ${ethers.formatUnits(fee.gasPrice, "gwei")} gwei, ${w.local ? "local" : w.canWrite ? "BROADCAST ENABLED" : "read only"}`);
  for (const [role, wallet] of Object.entries(w.wallets)) {
    console.log(`  ${role.padEnd(9)} ${wallet.address}  ${ethers.formatEther(await w.provider.getBalance(wallet.address))} native`);
  }
  if (!state) return console.log("not deployed yet");
  const { escrow, arbiter, usdc } = attach(state, w.provider);
  console.log(`escrow ${state.escrow}\narbiter ${state.arbiter}\nheld ${fmtUsdc(await usdc.balanceOf(state.escrow))}, jobs so far ${(await escrow.nextJobId()) - 1n}, window ${await arbiter.challengeWindow()}s, min bond ${ethers.formatEther(await arbiter.minBond())}`);
}

async function fund() {
  const w = await world();
  const from = w.wallets.owner;
  for (const [role, amount] of Object.entries(WANT)) {
    const to = w.wallets[role].address;
    const need = ethers.parseEther(amount) - (await w.provider.getBalance(to));
    if (need <= 0n) continue;
    if (!requireWrite(w, `send ${ethers.formatEther(need)} native from owner to ${role}`)) continue;
    const tx = await from.sendTransaction({ to, value: need });
    await tx.wait();
    console.log(`${role} +${ethers.formatEther(need)} ${link(w, tx.hash)}`);
  }
}

async function deployCmd() {
  const w = await world();
  if (loadState() && !flag("--redeploy")) throw new Error(`already deployed, see ${STATE_FILE}. Use --redeploy for a new set.`);
  const minBond = ethers.parseEther(opt("--min-bond") ?? "1");
  if (!requireWrite(w, `deploy escrow and arbiter (owner ${w.wallets.owner.address}, operator ${w.wallets.operator.address}, window 3600s, min bond ${ethers.formatEther(minBond)})`)) return;
  const set = await deployEscrowSet(w.wallets.owner, { usdc: opt("--usdc") ?? ARC_TESTNET.usdc, owner: w.wallets.owner.address, operator: w.wallets.operator.address, window: 3600n, minBond, bps: 0 });
  writeFileSync(STATE_FILE, JSON.stringify({ ...set, chainId: w.chainId }, null, 2));
  console.log(`escrow  ${set.escrow}\narbiter ${set.arbiter}\nsaved to ${STATE_FILE}`);
}

async function relayWorld(w) {
  const state = needState();
  const api = await apiConfig(w);
  const trustedKeys = trustedKeysFromRegistry(await fetchKeyRegistry(api.apiBase));
  if (trustedKeys.length === 0) throw new Error("the key registry has no usable attestation key");
  return { ...w, ...attach(state, w.provider), ...api, trustedKeys };
}

async function start() {
  const w = await relayWorld(await world());
  const path = { release: "/good", refund: "/empty" }[opt("--scene")];
  if (!path) throw new Error("--scene release|refund");
  if (!requireWrite(w, `run the ${opt("--scene")} scene for ${fmtUsdc(PRICE)}`)) return w.close();
  if (!w.apiKey) throw new Error("PREDGE_KEY is not set");
  const seller = await startSeller();
  try {
    const job = await payForJob(w, { spec: jobSpec(), amount: PRICE });
    console.log(`[1/4] PAY      job ${job.id}, ${fmtUsdc(PRICE)} ${link(w, job.payTxHash)}`);
    const delivery = await callSeller(seller.url, path);
    console.log(`[2/4] EVIDENCE seller answered ${delivery.status}: ${delivery.body} ${link(w, await fileDeliveryEvidence(w, job.id, delivery))}`);
    const verdict = await askForVerdict(w, job, delivery);
    console.log(`[3/4] VERDICT  ${verdict.attestation.payload.verdict} (${verdict.reason_codes.join(",")}) ${verdict.id}`);
    const { plan, txs } = await relay(w, job.id, verdict);
    if (plan.action === "human_review") return console.log("[4/4] RELAYER  inconclusive: no ruling, flagged for a human");
    console.log(`[4/4] RULE     ${plan.direction === Direction.Refund ? "REFUND" : "RELEASE"}, bond ${ethers.formatEther(plan.bond)} native ${link(w, txs.rule)}`);
    console.log(`Window is open for 1 hour. Then: node demo/job-escrow/cli.mjs keeper --broadcast (or dispute --job ${job.id} --as ${plan.direction === Direction.Refund ? "seller" : "refundTo"} --broadcast)`);
  } finally {
    seller.close();
    w.close();
  }
}

async function relayCmd() {
  const w = await relayWorld(await world());
  try {
    const job = opt("--job");
    if (!job) throw new Error("--job N");
    const verdict = opt("--verdict-file") ? JSON.parse(readFileSync(opt("--verdict-file"), "utf8")) : await fetchVerdict(w.apiBase, opt("--verdict-id"));
    if (!w.canWrite) {
      const plan = await planVerdict(w, job, verdict);
      console.log("Checks passed.", { action: plan.action, verdict: plan.verdict, direction: plan.direction, bond: plan.bond?.toString() });
      requireWrite(w, plan.action === "rule" ? "recordVerdict and rule" : "nothing: a human must look");
      return;
    }
    const { plan, txs } = await relay(w, job, verdict);
    console.log(plan.action === "human_review" ? "inconclusive: no ruling, flagged for a human" : `ruled, ${link(w, txs.rule)}`);
  } finally {
    w.close();
  }
}

async function keeper() {
  const w = await world();
  const contracts = attach(needState(), w.provider);
  const signer = w.canWrite ? w.wallets.operator : null; // the keeper only needs gas; its calls are permissionless
  const pass = () => keeperPass({ provider: w.provider, ...contracts }, signer, (m) => console.log(`${new Date().toISOString()} ${m}`));
  if (!signer) console.log("DRY RUN: reporting only.");
  const every = Number(opt("--watch") ?? 0);
  await pass();
  while (every > 0) {
    await new Promise((r) => setTimeout(r, every * 1000));
    await pass().catch((e) => console.error(e.shortMessage ?? e.message));
  }
}

async function disputeCmd() {
  const w = await world();
  const who = opt("--as");
  if (who !== "seller" && who !== "refundTo") throw new Error("--as seller|refundTo");
  const { arbiter } = attach(needState(), w.provider);
  const r = await arbiter.rulings(opt("--job"));
  if (r.status !== RulingStatus.Ruled) throw new Error("job has no open ruling");
  if (!requireWrite(w, `dispute job ${opt("--job")} as ${who}`)) return;
  const tx = await new Contract(arbiter.target, arbiter.interface, w.wallets[who]).dispute(opt("--job"), ethers.id(`counter evidence, job ${opt("--job")}`));
  await tx.wait();
  console.log(`disputed ${link(w, tx.hash)}`);
}

async function resolveCmd() {
  const w = await world();
  const final = { refund: Direction.Refund, release: Direction.Release }[opt("--final")];
  if (!final) throw new Error("--final refund|release");
  const { arbiter } = attach(needState(), w.provider);
  if (!requireWrite(w, `resolve job ${opt("--job")} as ${opt("--final")}`)) return;
  const tx = await new Contract(arbiter.target, arbiter.interface, w.wallets.owner).resolve(opt("--job"), final);
  await tx.wait();
  console.log(`resolved ${link(w, tx.hash)}. A final release still needs: keeper --broadcast`);
}

async function withdrawCmd() {
  const w = await world();
  const who = opt("--as");
  if (!["operator", "seller", "refundTo"].includes(who)) throw new Error("--as operator|seller|refundTo");
  const { arbiter } = attach(needState(), w.provider);
  const credit = await arbiter.credit(w.wallets[who].address);
  console.log(`${who} credit: ${ethers.formatEther(credit)} native`);
  if (credit === 0n || !requireWrite(w, `withdraw it to ${who}`)) return;
  const tx = await new Contract(arbiter.target, arbiter.interface, w.wallets[who]).withdraw();
  await tx.wait();
  console.log(`withdrawn ${link(w, tx.hash)}`);
}

const commands = { withdraw: withdrawCmd, keygen, status, fund, deploy: deployCmd, start, relay: relayCmd, keeper, dispute: disputeCmd, resolve: resolveCmd };
if (!commands[command]) {
  console.log("Commands:", Object.keys(commands).join(", "), "\nSee the top of this file.");
  process.exitCode = command ? 1 : 0;
} else {
  Promise.resolve(commands[command]())
    .then(() => process.exit(process.exitCode ?? 0))
    .catch((e) => {
      console.error(e.shortMessage ?? e.message);
      process.exit(1);
    });
}
