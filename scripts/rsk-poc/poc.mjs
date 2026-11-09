// Predge x IBUKI (Re.RISE) PoC on Rootstock TESTNET (chainId 31): deploy + end-to-end smoke.
//
//   node scripts/poc.mjs --rpc http://127.0.0.1:8545 --fork      dry run against a local anvil fork of RSK testnet
//     (anvil --fork-url https://public-node.testnet.rsk.co --chain-id 31 --base-fee 0)
//   CONFIRM_TESTNET=rootstock-testnet node scripts/poc.mjs --broadcast     real RSK testnet
//
// Deploys two pairs, both from unchanged AgentJobV2 v2.1 source plus PredgeNoObjectionEvaluator:
//   poc   : AgentJobV2(evaluationWindow = 24 days) + evaluator(objectionPeriod = 10 days)  -> IBUKI's first real job
//   smoke : AgentJobV2(evaluationWindow = 15 min)  + evaluator(objectionPeriod = 3 min)    -> today's end-to-end proof
// Then on the smoke pair: job A (no objection -> release to contractor -> withdraw) and job B (objection -> hold ->
// release refused -> reviewer decides refund -> client withdraws).
// Keys: ~/.predge-rsk/testnet-deployer.json + testnet-roles.json (throwaway, testnet only). Nothing secret is printed.
// Gas top-up for the new deployer comes from the 03.11 throwaway RSK-testnet deployer (~/predge-deploy-v2/.env.rsk-testnet).
import { JsonRpcProvider, Wallet, ContractFactory, Contract, AbiCoder, sha256, keccak256, toUtf8Bytes, formatEther } from "ethers";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const flag = (f) => args.includes(f);
const opt = (f, d) => (args.includes(f) ? args[args.indexOf(f) + 1] : d);
const FORK = flag("--fork");
const BROADCAST = flag("--broadcast");
if (FORK === BROADCAST) throw new Error("pass exactly one of --fork / --broadcast");
if (BROADCAST && process.env.CONFIRM_TESTNET !== "rootstock-testnet") throw new Error("set CONFIRM_TESTNET=rootstock-testnet");
const RPC = opt("--rpc", FORK ? "http://127.0.0.1:8545" : "https://public-node.testnet.rsk.co");
const EXPLORER = "https://explorer.testnet.rootstock.io";
const BLOCKSCOUT = "https://rootstock-testnet.blockscout.com";

const provider = new JsonRpcProvider(RPC, 31, { staticNetwork: true, cacheTimeout: -1 });
const net = await provider.getNetwork();
if (net.chainId !== 31n) throw new Error(`chainId ${net.chainId} is not Rootstock testnet (31)`);

const dir = join(homedir(), ".predge-rsk");
const dk = JSON.parse(readFileSync(join(dir, "testnet-deployer.json"), "utf8"));
const rk = JSON.parse(readFileSync(join(dir, "testnet-roles.json"), "utf8"));
const W = (pk) => new Wallet(pk, provider);
const deployer = W(dk.privateKey), client = W(rk.client.privateKey), contractor = W(rk.provider.privateKey), reviewer = W(rk.reviewer.privateKey);
const oldEnv = Object.fromEntries(readFileSync(join(homedir(), "predge-deploy-v2/.env.rsk-testnet"), "utf8").split("\n").filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]));
const oldDeployer = W(oldEnv.RSK_TESTNET_DEPLOYER_PRIVATE_KEY);

const art = (p) => JSON.parse(readFileSync(new URL(`../../build-v2/out/${p}`, import.meta.url), "utf8"));
const JOB = art("AgentJobV2.sol/AgentJobV2.json");
const EVAL = art("PredgeNoObjectionEvaluator.sol/PredgeNoObjectionEvaluator.json");

// Fork: use the live RSK testnet gas price so the dry run spends what the real run will (anvil needs --base-fee 0).
const gasPrice = FORK
  ? BigInt(await new JsonRpcProvider("https://public-node.testnet.rsk.co", 31, { staticNetwork: true }).send("eth_gasPrice", []))
  : BigInt(await provider.send("eth_gasPrice", []));
const txo = { type: 0, gasPrice };
const log = [];
const record = { chain: "rootstock-testnet", chainId: 31, mode: FORK ? "fork" : "broadcast", rpc: FORK ? "local anvil fork of public-node.testnet.rsk.co" : RPC, startedAt: new Date().toISOString(), gasPriceWei: gasPrice.toString(), roles: { deployer: deployer.address, client: client.address, contractor: contractor.address, reviewer: reviewer.address, gasSource: oldDeployer.address }, contracts: {}, txs: [], checks: [] };
const link = (h) => (FORK ? h : `${EXPLORER}/tx/${h}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitTx(label, txp) {
  const tx = await txp;
  let rc = null;
  for (let i = 0; i < 120 && !rc; i++) { rc = await provider.getTransactionReceipt(tx.hash); if (!rc) await sleep(FORK ? 200 : 5000); }
  if (!rc) throw new Error(`${label}: no receipt for ${tx.hash}`);
  if (rc.status !== 1) throw new Error(`${label}: reverted ${tx.hash}`);
  record.txs.push({ label, hash: tx.hash, block: rc.blockNumber, gasUsed: rc.gasUsed.toString(), from: tx.from });
  console.log(`  ok  ${label.padEnd(44)} ${link(tx.hash)}`);
  return rc;
}
function check(name, ok, detail = "") { record.checks.push({ check: name, ok: !!ok, detail: String(detail) }); console.log(`  ${ok ? "PASS" : "FAIL"} ${name}${detail ? "  " + detail : ""}`); if (!ok) throw new Error(`check failed: ${name}`); }
async function now() { return (await provider.getBlock("latest")).timestamp; }
async function waitUntil(ts) {
  if (FORK) { const t = await now(); if (t < ts) { await provider.send("evm_increaseTime", [ts - t + 1]); } await provider.send("evm_mine", []); return; }
  for (;;) { const t = await now(); if (t > ts) return; console.log(`  ..  waiting ${ts - t + 1}s for chain time`); await sleep(Math.min(60, ts - t + 5) * 1000); }
}
async function codeAt(addr) { for (let i = 0; i < 40; i++) { const c = await provider.getCode(addr); if (c && c !== "0x") return c; await sleep(FORK ? 100 : 5000); } throw new Error(`no code at ${addr}`); }

async function deploy(label, a, ctorArgs) {
  const f = new ContractFactory(a.abi, a.bytecode.object, deployer);
  const dtx = await f.getDeployTransaction(...ctorArgs);
  const tx = await deployer.sendTransaction({ ...dtx, ...txo });
  const rc = await waitTx(`deploy ${label}`, tx);
  await codeAt(rc.contractAddress);
  record.contracts[label] = { address: rc.contractAddress, tx: tx.hash, args: ctorArgs.map(String), explorer: FORK ? null : `${EXPLORER}/address/${rc.contractAddress}`, blockscout: FORK ? null : `${BLOCKSCOUT}/address/${rc.contractAddress}` };
  return new Contract(rc.contractAddress, a.abi, deployer);
}

console.log(`Rootstock testnet PoC (${record.mode}) via ${RPC}, gasPrice ${gasPrice} wei`);
for (const [k, v] of Object.entries(record.roles)) console.log(`  ${k.padEnd(10)} ${v}  ${formatEther(await provider.getBalance(v))} tRBTC`);

// ---- 1. gas
const want = { [deployer.address]: 120_000_000_000_000n, [client.address]: 30_000_000_000_000n, [contractor.address]: 12_000_000_000_000n, [reviewer.address]: 12_000_000_000_000n };
const total = Object.values(want).reduce((a, b) => a + b, 0n);
if ((await provider.getBalance(deployer.address)) < total) {
  await waitTx("top up new deployer from 03.11 throwaway", oldDeployer.sendTransaction({ to: deployer.address, value: total + 20_000_000_000_000n, gasLimit: 21000n, ...txo }));
}
for (const a of [client.address, contractor.address, reviewer.address]) {
  if ((await provider.getBalance(a)) < want[a]) await waitTx(`fund ${a.slice(0, 10)}`, deployer.sendTransaction({ to: a, value: want[a], gasLimit: 21000n, ...txo }));
}

// ---- 2. deploy
const DAY = 86400;
const job = await deploy("AgentJobV2_poc", JOB, [24 * DAY]);
const ev = await deploy("PredgeNoObjectionEvaluator_poc", EVAL, [await job.getAddress(), reviewer.address, 10 * DAY]);
const sjob = await deploy("AgentJobV2_smoke", JOB, [15 * 60]);
const sev = await deploy("PredgeNoObjectionEvaluator_smoke", EVAL, [await sjob.getAddress(), reviewer.address, 3 * 60]);
check("poc job.evaluationWindow == 24d", (await job.evaluationWindow()) === BigInt(24 * DAY));
check("poc evaluator.objectionPeriod == 10d", (await ev.objectionPeriod()) === BigInt(10 * DAY));
check("poc evaluator.job/reviewer", (await ev.job()) === (await job.getAddress()) && (await ev.reviewer()) === reviewer.address);
check("smoke evaluator.objectionPeriod == 180s, window 900s", (await sev.objectionPeriod()) === 180n && (await sev.evaluationWindow()) === 900n);

// ---- 3. smoke
const checklistDocHash = sha256(readFileSync(new URL("../../fixtures/rsk-poc/rerise-b2b-checklist.v1.json", import.meta.url)));
const items = JSON.parse(readFileSync(new URL("../../fixtures/rsk-poc/rerise-b2b-checklist.v1.json", import.meta.url), "utf8")).items;
const fileHashes = items.map((it) => sha256(toUtf8Bytes(`TESTNET DUMMY evidence file for ${it} (no real document)`)));
const manifest = AbiCoder.defaultAbiCoder().encode(["bytes32", "bytes32[]"], [checklistDocHash, fileHashes]);
const deliverable = sha256(manifest);
record.evidence = { checklistFile: "fixtures/rsk-poc/rerise-b2b-checklist.v1.json", checklistDocHash, items: items.length, fileHashes, manifestSha256: deliverable, note: "dummy file hashes; IBUKI's sample files not yet received" };
const ESCROW = 1_000_000_000_000n; // 0.000001 tRBTC
const sjobC = sjob.connect(client), sjobP = sjob.connect(contractor), sevC = sev.connect(client), sevR = sev.connect(reviewer);
const spec = await sev.specHashFor(checklistDocHash, items.length);

async function openAndSubmit(tag) {
  const exp = (await now()) + 3600;
  const rc = await waitTx(`${tag}: client createJob (escrow 1e12 wei)`, sjobC.createJob(contractor.address, await sev.getAddress(), spec, exp, { value: ESCROW, ...txo }));
  const id = sjob.interface.parseLog(rc.logs.find((l) => l.address.toLowerCase() === (sjob.target).toLowerCase())).args.jobId;
  await waitTx(`${tag}: contractor submit evidence manifest`, sjobP.submit(id, deliverable, manifest, txo));
  const j = await sjob.getJob(id);
  check(`${tag}: job ${id} Submitted, hashed on-chain, deliverable == sha256(manifest)`, j.state === 2n && j.hashedOnChain && j.deliverable === deliverable);
  check(`${tag}: packageComplete(checklist, 6 files)`, await sev.packageComplete(id, checklistDocHash, fileHashes));
  return { id, submittedAt: Number(j.submittedAt) };
}
async function expectRevert(name, p, errName) {
  try { await p; check(name, false, "did not revert"); } catch (e) {
    const data = e?.data ?? e?.info?.error?.data ?? e?.error?.data;
    let decoded = null; try { decoded = sev.interface.parseError(data)?.name; } catch {}
    check(name, decoded === errName, `reverted ${decoded ?? e.shortMessage ?? e.message}`);
  }
}

console.log("Job A: no objection -> release to contractor");
const A = await openAndSubmit("A");
await expectRevert("A: release before objection period ends is refused", sev.releaseOnSilence.staticCall(A.id, checklistDocHash, fileHashes), "ObjectionPeriodRunning");
console.log("Job B: objection -> hold");
const B = await openAndSubmit("B");
await waitTx("B: client files written objection (hash)", sevC.object(B.id, keccak256(toUtf8Bytes("TESTNET: written objection, after-work photos do not show the rear wall")), txo));
check("B: objection recorded", (await sev.objectionOf(B.id)).hash !== "0x" + "0".repeat(64));

await waitUntil(Math.max(A.submittedAt, B.submittedAt) + 180);
const balP0 = await provider.getBalance(contractor.address);
await waitTx("A: anyone (deployer) releaseOnSilence", sev.releaseOnSilence(A.id, checklistDocHash, fileHashes, txo));
check("A: job Completed, contractor credited escrow", (await sjob.getJob(A.id)).state === 3n && (await sjob.credit(contractor.address)) === ESCROW);
const wrc = await waitTx("A: contractor withdraws", sjobP.withdraw(txo));
const balP1 = await provider.getBalance(contractor.address);
check("A: contractor balance += escrow - gas", balP1 - balP0 === ESCROW - wrc.gasUsed * (wrc.gasPrice ?? gasPrice), `${balP1 - balP0} wei net`);

await expectRevert("B: releaseOnSilence refused while on hold", sev.releaseOnSilence.staticCall(B.id, checklistDocHash, fileHashes), "OnHold");
check("B: job still Submitted (held in escrow)", (await sjob.getJob(B.id)).state === 2n);
await expectRevert("B: a non-reviewer cannot resolve", sev.connect(contractor).resolve.staticCall(B.id, true, keccak256(toUtf8Bytes("x"))), "NotReviewer");
await waitTx("B: reviewer resolves -> refund client", sevR.resolve(B.id, false, keccak256(toUtf8Bytes("TESTNET: human review decision, refund")), txo));
check("B: job Rejected, client credited escrow", (await sjob.getJob(B.id)).state === 4n && (await sjob.credit(client.address)) === ESCROW);
await waitTx("B: client withdraws refund", sjobC.withdraw(txo));
check("smoke job contract holds nothing", (await sjob.totalEscrowed()) === 0n && (await sjob.totalCredit()) === 0n && (await provider.getBalance(sjob.target)) === 0n);

record.jobs = { A: { jobId: A.id.toString(), outcome: "no objection -> released to contractor -> withdrawn" }, B: { jobId: B.id.toString(), outcome: "objection -> held -> reviewer refund -> withdrawn" } };
record.finishedAt = new Date().toISOString();
for (const [k, v] of Object.entries(record.roles)) record.roles[k + "BalanceAfter"] = formatEther(await provider.getBalance(v));
mkdirSync(new URL("../../deployments/rsk-poc/", import.meta.url), { recursive: true });
const out = new URL(`../../deployments/rsk-poc/rootstock-testnet${FORK ? ".fork" : ""}.json`, import.meta.url);
writeFileSync(out, JSON.stringify(record, (k, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
console.log(`\nALL ${record.checks.length} CHECKS PASS. Record: ${out.pathname}`);
