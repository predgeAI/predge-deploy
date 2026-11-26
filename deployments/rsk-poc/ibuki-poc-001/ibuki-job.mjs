// IBUKI-POC-001: the first real (testnet) job with IBUKI's evidence files, on the PoC pair deployed 09.11.2026.
//   CONFIRM_TESTNET=rootstock-testnet node scripts/ibuki-job.mjs <evidence-dir> <out-dir>
// Escrows 1e12 wei tRBTC (client -> AgentJobV2 PoC), contractor submits the evidence manifest (only hashes on-chain),
// 10-day no-objection period starts. Writes evidence-package.json + an ed25519-signed record. Nothing secret is printed.
import { JsonRpcProvider, Wallet, Contract, AbiCoder, sha256, getBytes, concat, formatEther } from "ethers";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import { generateKeyPairSync, sign, createPublicKey } from "node:crypto";

if (process.env.CONFIRM_TESTNET !== "rootstock-testnet") throw new Error("set CONFIRM_TESTNET=rootstock-testnet");
const [EVD, OUT] = process.argv.slice(2);
mkdirSync(OUT, { recursive: true });
const RPC = "https://public-node.testnet.rsk.co", EXPLORER = "https://explorer.testnet.rootstock.io";
const JOB_ADDR = "0x5eAe41E4a082e6F5fDda067535757927c2716844", EV_ADDR = "0xc1e3259a417FD06781941cA973dB6e58274DA683";
const provider = new JsonRpcProvider(RPC, 31, { staticNetwork: true, cacheTimeout: -1 });
const rk = JSON.parse(readFileSync(join(homedir(), ".predge-rsk/testnet-roles.json"), "utf8"));
const dk = JSON.parse(readFileSync(join(homedir(), ".predge-rsk/testnet-deployer.json"), "utf8"));
const client = new Wallet(rk.client.privateKey, provider), contractor = new Wallet(rk.provider.privateKey, provider), deployer = new Wallet(dk.privateKey, provider);
const art = (p) => JSON.parse(readFileSync(new URL(`../out/${p}`, import.meta.url), "utf8")).abi;
const job = new Contract(JOB_ADDR, art("AgentJobV2.sol/AgentJobV2.json"), provider);
const ev = new Contract(EV_ADDR, art("PredgeNoObjectionEvaluator.sol/PredgeNoObjectionEvaluator.json"), provider);
const gasPrice = BigInt(await provider.send("eth_gasPrice", [])); const txo = { type: 0, gasPrice };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const txs = [];
async function waitTx(label, p) { const tx = await p; let rc = null; for (let i = 0; i < 120 && !rc; i++) { rc = await provider.getTransactionReceipt(tx.hash); if (!rc) await sleep(5000); } if (!rc || rc.status !== 1) throw new Error(`${label} failed ${tx.hash}`); txs.push({ label, hash: tx.hash, block: rc.blockNumber, url: `${EXPLORER}/tx/${tx.hash}` }); console.log(`ok ${label} ${EXPLORER}/tx/${tx.hash}`); return rc; }

// checklist (same doc as committed in the smoke run) and item -> files mapping
const checklistBytes = readFileSync(new URL("../fixtures/rerise-b2b-checklist.v1.json", import.meta.url));
const checklistDocHash = sha256(checklistBytes);
const items = JSON.parse(checklistBytes.toString()).items;
const map = {
  "before-work-photographs": ["01-before.jpg"],
  "during-work-photographs": ["02-demolition-start.jpg", "03-in-progress.jpg", "04-foundation-debris.jpg"],
  "after-work-photographs": ["05-after-grading.jpg"],
  "completion-report": ["07-completion-report.pdf"],
  "manifest-copies-or-receiving-facility-receipts": ["08-manifests.pdf"],
  "joint-site-inspection-or-remote-review-record": ["06-photo-report.pdf"],
};
const files = {}; const itemHashes = [];
const itemsOut = items.map((it) => {
  const fs = map[it]; if (!fs) throw new Error(`no files for ${it}`);
  const hs = fs.map((f) => { const p = join(EVD, f); if (!existsSync(p)) throw new Error(`missing ${p}`); const h = sha256(readFileSync(p)); files[f] = h; return h; });
  const itemHash = hs.length === 1 ? hs[0] : sha256(concat(hs.map(getBytes)));
  itemHashes.push(itemHash);
  return { item: it, files: fs, fileSha256: hs, itemHash, rule: hs.length === 1 ? "itemHash = sha256(file)" : "itemHash = sha256(concat(sha256(file_i)))" };
});
const manifest = AbiCoder.defaultAbiCoder().encode(["bytes32", "bytes32[]"], [checklistDocHash, itemHashes]);
const deliverable = sha256(manifest);
const spec = await ev.specHashFor(checklistDocHash, items.length);

// gas for client/contractor if needed
for (const w of [client, contractor]) { const b = await provider.getBalance(w.address); if (b < 8_000_000_000_000n) await waitTx(`fund ${w.address.slice(0, 10)}`, deployer.sendTransaction({ to: w.address, value: 10_000_000_000_000n, gasLimit: 21000n, ...txo })); }
const ESCROW = 1_000_000_000_000n;
const exp = (await provider.getBlock("latest")).timestamp + 2 * 86400;
const rc = await waitTx("IBUKI-POC-001: client createJob (escrow 0.000001 tRBTC)", job.connect(client).createJob(contractor.address, EV_ADDR, spec, exp, { value: ESCROW, ...txo }));
const jobId = job.interface.parseLog(rc.logs.find((l) => l.address.toLowerCase() === JOB_ADDR.toLowerCase())).args.jobId;
await waitTx("IBUKI-POC-001: contractor submits evidence manifest", job.connect(contractor).submit(jobId, deliverable, manifest, txo));
const j = await job.getJob(jobId);
const complete = await ev.packageComplete(jobId, checklistDocHash, itemHashes);
const deadline = Number(await ev.objectionDeadline(jobId));
if (!(j.state === 2n && j.hashedOnChain && j.deliverable === deliverable && complete)) throw new Error("post-submit checks failed");

const pkg = { title: "IBUKI-POC-001 evidence package (Rootstock testnet, simulated data)", chainId: 31, jobContract: JOB_ADDR, evaluator: EV_ADDR, jobId: jobId.toString(),
  roles: { client: client.address, contractor: contractor.address, reviewer: await ev.reviewer() }, escrowWei: ESCROW.toString(),
  checklist: { file: "rerise-b2b-checklist.v1.json", sha256: checklistDocHash, items: items.length }, items: itemsOut, files,
  manifestSha256OnChain: deliverable, specHash: spec, packageComplete: complete, submittedAt: new Date(Number(j.submittedAt) * 1000).toISOString(),
  objectionDeadline: new Date(deadline * 1000).toISOString(), objectionPeriodDays: 10,
  rule: "If the client files no objection by the deadline, anyone can call releaseOnSilence and the escrow is credited to the contractor. An objection holds it for the reviewer.",
  transactions: txs, createdAt: new Date().toISOString(), note: "Testnet only. Files are IBUKI's sample documents; dates and parties are simulated. Only hashes are on-chain." };
writeFileSync(join(OUT, "evidence-package.json"), JSON.stringify(pkg, null, 2) + "\n");
// ed25519-signed record (throwaway testnet signing key, public key published with the record)
const kp = join(homedir(), ".predge-rsk/testnet-ed25519.pem");
let priv;
if (existsSync(kp)) { priv = readFileSync(kp, "utf8"); } else { const { privateKey } = generateKeyPairSync("ed25519"); priv = privateKey.export({ type: "pkcs8", format: "pem" }); writeFileSync(kp, priv, { mode: 0o600 }); }
const body = readFileSync(join(OUT, "evidence-package.json"));
const sig = sign(null, body, priv).toString("base64");
const pub = createPublicKey(priv).export({ type: "spki", format: "der" }).subarray(-32).toString("hex");
writeFileSync(join(OUT, "evidence-package.sig.json"), JSON.stringify({ alg: "ed25519", signs: "evidence-package.json (exact bytes)", publicKeyHex: pub, signatureBase64: sig, note: "Predge TESTNET signing key for the IBUKI PoC" }, null, 2) + "\n");
console.log(JSON.stringify({ jobId: jobId.toString(), deadline: pkg.objectionDeadline, complete, pub }, null, 0));
