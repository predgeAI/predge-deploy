#!/usr/bin/env node
// One command, no keys, no network: `npm run demo:job-escrow`.
// Starts its own anvil, deploys everything with throwaway wallets, runs every scene, checks every balance,
// stops anvil. Exit code 0 means every check passed. DEMO ONLY, UNAUDITED, TESTNET ONLY.
//
//   --api live     use api.predge.io with PREDGE_KEY instead of the local stand-in
//
// An anvil fork of Arc testnet does not work: Arc's USDC moves funds through a native-coin precompile
// that anvil does not have, so transfers revert. Tested 4 Nov 2026. This demo therefore uses MockUSDC.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { Contract, ethers, parseEther, parseUnits, Wallet } from "ethers";
import { fetchKeyRegistry } from "./lib/api.mjs";
import { attach, artifacts, deploy, deployEscrowSet, fmtUsdc, guardKey, guardNetwork, JobState, RulingStatus, revertName } from "./lib/chain.mjs";
import { keeperPass } from "./lib/keeper.mjs";
import { buildVerdict, ephemeralSigner, startMockApi } from "./lib/mock-api.mjs";
import { startSeller } from "./lib/seller.mjs";
import { askForVerdict, callSeller, fileDeliveryEvidence, jobSpec, payForJob, relay, verdictRequest } from "./lib/scenario.mjs";
import { attestationHashOf, Direction, trustedKeysFromRegistry, VerdictRejected } from "./lib/verdict.mjs";

const args = process.argv.slice(2);
const argValue = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const useLiveApi = argValue("--api") === "live";

const PRICE = parseUnits("10", 6); // 6 decimals: the ERC-20 side of USDC
const BOND = parseEther("5"); // 18 decimals: the native side, what the arbiter sizes bonds in
const WINDOW = 3600n;

let failures = 0;
function check(ok, what) {
  if (ok) {
    console.log(`        ok   ${what}`);
  } else {
    failures += 1;
    console.log(`        FAIL ${what}`);
  }
}
const scene = (title) => console.log(`\n--- ${title}`);
const step = (i, n, label, text) => console.log(`[${i}/${n}] ${label.padEnd(8)} ${text}`);

const foundryBin = (name) => {
  const p = join(homedir(), ".foundry/bin", name);
  return existsSync(p) ? p : name;
};

const freePort = () =>
  new Promise((resolve, reject) => {
    const s = createServer();
    s.on("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });

async function startAnvil() {
  const port = await freePort();
  const proc = spawn(foundryBin("anvil"), ["--port", String(port), "--host", "127.0.0.1", "--silent"], { stdio: "ignore" });
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' });
      if (res.ok) return { url, stop: () => proc.kill() };
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  proc.kill();
  throw new Error("anvil did not start");
}

async function timeTravel(provider, seconds) {
  await provider.send("evm_increaseTime", [Number(seconds)]);
  await provider.send("evm_mine", []);
}

/** Expect a rejection with this code from the off-chain checks. */
async function expectRejected(code, fn, what) {
  try {
    await fn();
    check(false, `${what}: was not rejected`);
  } catch (e) {
    if (e instanceof VerdictRejected) check(e.code === code, `${what}: refused off chain (${e.code})`);
    else check(false, `${what}: unexpected error ${e.message}`);
  }
}

async function main() {
  console.log("Predge Job Escrow. DEMO ONLY, UNAUDITED, TESTNET ONLY. Local chain, nothing is sent to any network.");
  artifacts(); // fails early with a clear message if the contracts are not built

  const anvil = await startAnvil();
  const rpcUrl = anvil.url;
  const provider = new ethers.JsonRpcProvider(rpcUrl, undefined, { cacheTimeout: -1, pollingInterval: 50 });
  const seller = await startSeller();
  const api = useLiveApi ? null : await startMockApi();

  try {
    const { chainId, local } = await guardNetwork(provider, rpcUrl, { broadcast: true });
    if (!local) throw new Error("run.mjs is local only");
    console.log(`Local anvil (chain ${chainId}), MockUSDC 6 decimals.`);

    // Throwaway wallets, random on every run. No key is stored or printed.
    const wallet = async (units) => {
      const w = guardKey(Wallet.createRandom().connect(provider));
      await provider.send("anvil_setBalance", [w.address, ethers.toQuantity(units)]);
      return w;
    };
    const fund = parseEther("100");
    const wallets = { deployer: await wallet(fund), owner: await wallet(fund), operator: await wallet(fund), buyer: await wallet(fund), refundTo: await wallet(fund), seller: await wallet(fund), keeper: await wallet(fund) };

    const mock = await deploy(wallets.deployer, "usdc");
    const usdcAddress = await mock.getAddress();
    await (await mock.mint(wallets.buyer.address, parseUnits("1000", 6))).wait();
    const set = await deployEscrowSet(wallets.deployer, { usdc: usdcAddress, owner: wallets.owner.address, operator: wallets.operator.address, window: WINDOW, minBond: BOND, bps: 0 });
    const { escrow, arbiter, usdc } = attach(set, provider);
    console.log(`Deployed escrow ${set.escrow}, arbiter ${set.arbiter}. Decimals: USDC ${await usdc.decimals()}, scale ${await escrow.amountScale()}.`);
    console.log(`On-chain label: "${await escrow.DEMO_NOTICE()}"`);

    const apiBase = useLiveApi ? "https://api.predge.io" : api.url;
    const apiKey = useLiveApi ? process.env.PREDGE_KEY : "local-demo-key";
    const trustedKeys = trustedKeysFromRegistry(await fetchKeyRegistry(apiBase));
    console.log(useLiveApi ? "Verdicts: api.predge.io, checked against its published keys." : "Verdicts: LOCAL STAND-IN with a throwaway key (same format). Use --api live for api.predge.io.");

    const w = { provider, chainId, escrow, arbiter, usdc, wallets, apiBase, apiKey, trustedKeys };
    const balances = async () => ({ refundTo: await usdc.balanceOf(wallets.refundTo.address), seller: await usdc.balanceOf(wallets.seller.address), held: await usdc.balanceOf(set.escrow) });
    const asKeeper = () => keeperPass(w, wallets.keeper);

    // ---------- 1 ----------
    scene("Scene 1: good delivery -> verdict delivered -> automatic release");
    let b0 = await balances();
    const job1 = await payForJob(w, { spec: jobSpec(), amount: PRICE });
    step(1, 7, "PAY", `buyer-agent -> escrow: ${fmtUsdc(PRICE)} for job ${job1.id}, seller-agent named, refund wallet named`);
    check((await balances()).held === b0.held + PRICE, "USDC is in the escrow, 6dp");
    const [, , scaled] = await escrow.paymentInfo(job1.id);
    check(scaled === PRICE * 10n ** 12n, `arbiter sees ${ethers.formatEther(scaled)} in 18dp`);
    const d1 = await callSeller(seller.url, "/good");
    step(2, 7, "DELIVER", `seller API answered ${d1.status}: ${d1.body}`);
    await (await new Contract(set.escrow, escrow.interface, wallets.seller).markDelivered(job1.id, ethers.sha256(ethers.toUtf8Bytes(d1.body)))).wait();
    await fileDeliveryEvidence(w, job1.id, d1);
    step(3, 7, "EVIDENCE", "refund wallet filed the hash of what it received; seller marked delivered");
    const v1 = await askForVerdict(w, job1, d1);
    step(4, 7, "VERDICT", `${v1.attestation.payload.verdict} (${v1.reason_codes.join(",")}), ed25519 signed, ${v1.id}`);
    const r1 = await relay(w, job1.id, v1);
    step(5, 7, "RULE", `relayer checked signature and job, recorded the hash, posted ${ethers.formatEther(r1.plan.bond)} native bond: RELEASE`);
    check(r1.plan.direction === Direction.Release, "delivered maps to Release");
    check((await balances()).seller === b0.seller, "nothing moved at the ruling");
    const earlyPass = await asKeeper();
    check(earlyPass.length === 0, "keeper does nothing while the window is open");
    await timeTravel(provider, WINDOW);
    step(6, 7, "WINDOW", "1 hour challenge window passed with no dispute (time travel, local only)");
    const pass1 = await asKeeper();
    check(pass1.some((a) => a.id === job1.id && a.action === "settle"), "keeper called settle");
    let b1 = await balances();
    step(7, 7, "RESULT", `seller +${fmtUsdc(b1.seller - b0.seller)}, automatically`);
    check(b1.seller === b0.seller + PRICE, "seller got exactly the price");
    check((await escrow.jobs(job1.id)).state === JobState.Released, "job is Released");
    check((await arbiter.credit(wallets.operator.address)) === BOND, "operator's bond is withdrawable again");

    // ---------- 2 ----------
    scene("Scene 2: seller answers 200 {} -> verdict not_delivered -> automatic refund");
    b0 = await balances();
    const job2 = await payForJob(w, { spec: jobSpec(), amount: PRICE });
    step(1, 6, "PAY", `${fmtUsdc(PRICE)} for job ${job2.id}`);
    const d2 = await callSeller(seller.url, "/empty");
    step(2, 6, "DELIVER", `seller API answered ${d2.status}: ${d2.body}`);
    await fileDeliveryEvidence(w, job2.id, d2);
    const v2 = await askForVerdict(w, job2, d2);
    step(3, 6, "VERDICT", `${v2.attestation.payload.verdict} (${v2.reason_codes.join(",")})`);
    const r2 = await relay(w, job2.id, v2);
    step(4, 6, "RULE", "REFUND, bond posted");
    check(r2.plan.direction === Direction.Refund, "not_delivered maps to Refund");
    await timeTravel(provider, WINDOW);
    step(5, 6, "WINDOW", "no dispute");
    await asKeeper();
    b1 = await balances();
    step(6, 6, "RESULT", `refund wallet +${fmtUsdc(b1.refundTo - b0.refundTo)}`);
    check(b1.refundTo === b0.refundTo + PRICE, "the refund went to refundTo");
    check(b1.seller === b0.seller, "seller got nothing");

    // ---------- 3 ----------
    scene("Scene 3: seller disputes a refund -> owner overturns -> seller paid, bond slashed to seller");
    b0 = await balances();
    const job3 = await payForJob(w, { spec: jobSpec(), amount: PRICE });
    const d3 = await callSeller(seller.url, "/empty");
    await fileDeliveryEvidence(w, job3.id, d3);
    await relay(w, job3.id, await askForVerdict(w, job3, d3));
    step(1, 4, "RULE", `job ${job3.id}: REFUND`);
    await (await new Contract(set.arbiter, arbiter.interface, wallets.seller).dispute(job3.id, ethers.id("seller: here is proof of delivery"))).wait();
    step(2, 4, "DISPUTE", "seller disputed inside the window; the funds are frozen");
    await timeTravel(provider, WINDOW);
    check((await keeperPass(w, null)).every((a) => a.id !== job3.id), "keeper leaves a disputed job alone");
    await (await new Contract(set.arbiter, arbiter.interface, wallets.owner).resolve(job3.id, Direction.Release)).wait();
    step(3, 4, "RESOLVE", "owner overturned the ruling: final direction Release");
    const ruling3 = await arbiter.rulings(job3.id);
    check(ruling3.status === RulingStatus.Overturned && ruling3.direction === BigInt(Direction.Refund), "stored direction is still the original Refund");
    await asKeeper();
    b1 = await balances();
    step(4, 4, "RESULT", `seller +${fmtUsdc(b1.seller - b0.seller)}, seller credited ${ethers.formatEther(await arbiter.credit(wallets.seller.address))} native from the operator's bond`);
    check(b1.seller === b0.seller + PRICE, "an overturned Refund pays the seller");
    check(b1.refundTo === b0.refundTo, "and does not refund");
    check((await arbiter.credit(wallets.seller.address)) === BOND, "the bond went to the harmed party");

    // ---------- 4 ----------
    scene("Scene 4: payer disputes a release -> owner overturns -> refund");
    b0 = await balances();
    const job4 = await payForJob(w, { spec: jobSpec(), amount: PRICE });
    const d4 = await callSeller(seller.url, "/good");
    await fileDeliveryEvidence(w, job4.id, d4);
    await relay(w, job4.id, await askForVerdict(w, job4, d4));
    step(1, 3, "RULE", `job ${job4.id}: RELEASE`);
    await (await new Contract(set.arbiter, arbiter.interface, wallets.refundTo).dispute(job4.id, ethers.id("payer: this is not what was ordered"))).wait();
    step(2, 3, "DISPUTE", "refund wallet disputed inside the window");
    await (await new Contract(set.arbiter, arbiter.interface, wallets.owner).resolve(job4.id, Direction.Refund)).wait();
    b1 = await balances();
    step(3, 3, "RESULT", `owner overturned; refund wallet +${fmtUsdc(b1.refundTo - b0.refundTo)} inside resolve`);
    check(b1.refundTo === b0.refundTo + PRICE, "an overturned Release refunds");
    check(b1.seller === b0.seller, "and does not pay the seller");

    // ---------- 5 ----------
    scene("Scene 5: no delivery by the deadline -> refund with no verdict at all");
    b0 = await balances();
    const job5 = await payForJob(w, { spec: jobSpec(), amount: PRICE });
    step(1, 3, "PAY", `job ${job5.id}, deadline in 1 hour`);
    await timeTravel(provider, 3601n);
    step(2, 3, "DEADLINE", "the seller never delivered");
    await asKeeper();
    b1 = await balances();
    step(3, 3, "RESULT", `keeper called refundAfterDeadline; refund wallet +${fmtUsdc(b1.refundTo - b0.refundTo)}`);
    check(b1.refundTo === b0.refundTo + PRICE, "deadline refund paid");

    // ---------- 6 ----------
    scene("Scene 6: verdict inconclusive -> nothing on chain, flagged for a human");
    b0 = await balances();
    const job6 = await payForJob(w, { spec: jobSpec({ max_latency_ms: 5000 }), amount: PRICE });
    const d6 = await callSeller(seller.url, "/good", { reportLatency: false });
    const v6 = await askForVerdict(w, job6, d6);
    step(1, 3, "VERDICT", `${v6.attestation.payload.verdict} (${v6.reason_codes.join(",")}): the spec has a latency limit and the evidence has no latency`);
    const r6 = await relay(w, job6.id, v6);
    step(2, 3, "RELAYER", "no ruling; flagged for a human");
    check(r6.plan.action === "human_review" && !r6.txs, "no transaction was sent");
    check((await arbiter.rulings(job6.id)).status === RulingStatus.None, "no ruling exists");
    await timeTravel(provider, 3601n);
    await asKeeper();
    b1 = await balances();
    step(3, 3, "RESULT", "the money is not stuck: with no delivery claim, the deadline refund still applies");
    check(b1.refundTo === b0.refundTo + PRICE, "refunded at the deadline");

    // ---------- 7 ----------
    scene("Scene 7: attacks on the verdict path, all refused before any money moves");
    const job7 = await payForJob(w, { spec: jobSpec(), amount: PRICE });
    const d7 = await callSeller(seller.url, "/good");
    await fileDeliveryEvidence(w, job7.id, d7);

    const attacker = ephemeralSigner();
    const forged = buildVerdict(attacker, verdictRequest(w, job7, d7));
    await expectRejected("wrong_signer", () => relay(w, job7.id, forged), "verdict signed by another key");

    const genuine = await askForVerdict(w, job7, d7);
    const flipped = structuredClone(genuine);
    flipped.attestation.payload.verdict = "not_delivered";
    await expectRejected("payload_mismatch", () => relay(w, job7.id, flipped), "signed payload edited");

    const tampered = structuredClone(genuine);
    tampered.attestation.canonical = tampered.attestation.canonical.replace('"delivered"', '"not_delivered"');
    tampered.attestation.payload.verdict = "not_delivered";
    await expectRejected("bad_signature", () => relay(w, job7.id, tampered), "signed bytes edited");

    await expectRejected("wrong_payment", () => relay(w, job7.id, v1), "scene 1's genuine verdict replayed on a new job");
    await expectRejected("job_not_active", () => relay(w, job1.id, v1), "scene 1's verdict replayed on its own settled job");

    const otherSpec = await askForVerdict(w, { ...job7, spec: jobSpec({ endpoint: "https://seller.demo.invalid/other" }) }, d7);
    await expectRejected("wrong_job", () => relay(w, job7.id, otherSpec), "genuine verdict about a different job spec");

    const otherAmount = await askForVerdict(w, { ...job7, amount: PRICE - 1n }, d7);
    await expectRejected("wrong_amount", () => relay(w, job7.id, otherAmount), "genuine verdict about a different amount");

    // The chain refuses too, for a relayer that skipped its checks.
    const opEscrow = new Contract(set.escrow, escrow.interface, wallets.operator);
    const usedHash = attestationHashOf(v1.attestation);
    const usedFor = await escrow.attestationJob(usedHash);
    try {
      await opEscrow.recordVerdict.staticCall(job7.id, usedHash, Direction.Release);
      check(false, "on-chain replay: not refused");
    } catch (e) {
      check(revertName(e, escrow) === "VerdictReplayed", `same verdict hash, on chain: ${revertName(e, escrow)} (already used for job ${usedFor})`);
    }
    try {
      await new Contract(set.escrow, escrow.interface, wallets.keeper).recordVerdict.staticCall(job7.id, ethers.id("x"), Direction.Release);
      check(false, "wrong operator: not refused");
    } catch (e) {
      check(revertName(e, escrow) === "NotOperator", `wrong operator key, on chain: ${revertName(e, escrow)}`);
    }
    check((await escrow.jobs(job7.id)).state === JobState.Funded, "job 7's money has not moved");

    await relay(w, job7.id, genuine);
    step(1, 1, "RESULT", "the genuine verdict is still accepted after all of that");
    check((await arbiter.rulings(job7.id)).status === RulingStatus.Ruled, "ruled");

    // ---------- end ----------
    await timeTravel(provider, WINDOW);
    await asKeeper();
    const leftover = await usdc.balanceOf(set.escrow);
    scene("Totals");
    check(leftover === 0n, `escrow holds ${fmtUsdc(leftover)} at the end`);
    check((await escrow.totalHeld()) === 0n, "totalHeld is 0");

    console.log(failures === 0 ? "\nALL CHECKS PASSED. Local chain only. Contract is unaudited: demo, testnet only." : `\n${failures} CHECK(S) FAILED.`);
    process.exitCode = failures === 0 ? 0 : 1;
  } finally {
    seller.close();
    api?.close();
    provider.destroy();
    anvil.stop();
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
