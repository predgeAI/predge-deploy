// v2 smoke checks. `readOnlyV2` runs on a live chain (eth_call only). `e2eV2` runs on a local fork ONLY, with the
// public anvil accounts: the full honest path through every contract, then the v1 attack sequences (H-01, H-02,
// H-03 and the self-challenge) which must now revert or be harmless.
import { Contract, keccak256, toUtf8Bytes, sha256, AbiCoder, ZeroAddress, ZeroHash } from "ethers";
import { maskImmutables } from "./compile.mjs";
import { waitReceipt } from "./chains.mjs";

const coder = AbiCoder.defaultAbiCoder();
const h = (s) => keccak256(toUtf8Bytes(s));
const step = (plan, name) => plan.find((s) => s.name === name);
const at = (plan, name, runner) => new Contract(step(plan, name).address, step(plan, name).compiled.abi, runner);

export async function readOnlyV2(provider, plan, roles) {
  const checks = [];
  const ok = (name, cond, detail) => { checks.push({ check: name, ok: !!cond, detail: String(detail ?? "") }); if (!cond) throw new Error(`v2 smoke failed: ${name} (${detail})`); };

  for (const s of plan) {
    const code = await provider.getCode(s.address);
    const c = s.compiled;
    ok(`${s.name} runtime == compiled`, maskImmutables(code, c.immutableReferences) === maskImmutables(c.deployedBytecode, c.immutableReferences), s.address);
  }
  const reg = at(plan, "PredgeAgentValidatorV2", provider);
  const job = at(plan, "AgentJobV2", provider);
  const bond = at(plan, "PredgeValidatorBondV2", provider);
  const settle = at(plan, "PredgeSettlementV2", provider);
  const arb = at(plan, "PredgeRefundArbiterV2", provider);
  const mock = at(plan, "MockRefundProtocolV2", provider);
  const [bondArgs, arbArgs] = [step(plan, "PredgeValidatorBondV2").args, step(plan, "PredgeRefundArbiterV2").args];

  for (const [n, c] of [["registry", reg], ["bond", bond], ["settlement", settle], ["arbiter", arb]]) {
    ok(`${n}.owner == owner (not the deployer)`, (await c.owner()) === roles.owner && roles.owner !== roles.deployer, await c.owner());
    ok(`${n}.pendingOwner == 0`, (await c.pendingOwner()) === ZeroAddress, "");
  }
  for (const [n, c] of [["registry", reg], ["bond", bond], ["arbiter", arb]]) ok(`${n}.operator == operator`, (await c.operator()) === roles.operator, await c.operator());
  ok("no contract has a renounceOwnership", await noSelector(provider, plan, "renounceOwnership()"), "");
  ok("registry.identityRegistry", (await reg.identityRegistry()) === step(plan, "PredgeAgentValidatorV2").args[2], await reg.identityRegistry());
  ok("job.evaluationWindow", (await job.evaluationWindow()) === BigInt(step(plan, "AgentJobV2").args[0]), "");
  ok("job.jobCount == 0", (await job.jobCount()) === 0n, "");
  ok("bond.job == AgentJobV2", (await bond.job()) === job.target, await bond.job());
  ok("bond params", (await bond.disputeWindow()) === BigInt(bondArgs[3]) && (await bond.minBond()) === BigInt(bondArgs[4]) && (await bond.bondBps()) === BigInt(bondArgs[5]), "");
  ok("bond.wouldSlash(unknown) == false", (await bond.wouldSlash(h("predge/smoke/none"))) === false, "");
  ok("arbiter.refundProtocol == mock", (await arb.refundProtocol()) === mock.target, await arb.refundProtocol());
  ok("mock.arbiter == arbiter", (await mock.arbiter()) === arb.target, await mock.arbiter());
  ok("arbiter params", (await arb.challengeWindow()) === BigInt(arbArgs[3]) && (await arb.minBond()) === BigInt(arbArgs[4]) && (await arb.bondBps()) === BigInt(arbArgs[5]), "");
  ok("registry.requestHashFor is domain separated", (await reg.requestHashFor(1n, h("d"))) === keccak256(coder.encode(["uint256", "address", "uint256", "bytes32"], [(await provider.getNetwork()).chainId, reg.target, 1n, h("d")])), "");
  ok("bond.specHashFor is domain separated", (await bond.specHashFor(h("c"))) === keccak256(coder.encode(["uint256", "address", "bytes32"], [(await provider.getNetwork()).chainId, bond.target, h("c")])), "");
  return checks;
}

async function noSelector(provider, plan, sig) {
  const data = keccak256(toUtf8Bytes(sig)).slice(0, 10);
  for (const s of plan) {
    if (s.name === "MockRefundProtocolV2" || s.name === "AgentJobV2") continue;
    const r = await provider.call({ to: s.address, data }).then(() => "returned", () => "reverted");
    if (r !== "reverted") return false;
  }
  return true;
}

/** `s` = { owner, op, client, worker, party } connected signers on the fork. */
export async function e2eV2(provider, plan, s, increaseTime) {
  const steps = [];
  const send = async (label, p) => { const tx = await p; const r = await waitReceipt(provider, tx.hash); if (r.status !== 1) throw new Error(`e2e ${label} reverted`); steps.push({ step: label, gasUsed: Number(r.gasUsed) }); return r; };
  const attacks = [];
  /** An attack step passes only if the call reverts with the named custom error. */
  const mustRevert = async (label, name, fn) => {
    try { await fn(); } catch (e) {
      const got = e.revert?.name ?? e.shortMessage ?? e.message;
      if (got !== name) throw new Error(`attack "${label}" reverted with ${got}, expected ${name}`);
      attacks.push({ attack: label, blockedBy: name }); return;
    }
    throw new Error(`attack "${label}" SUCCEEDED, expected revert ${name}`);
  };
  const addr = async (w) => w.getAddress();
  const [owner, op, client, worker, party] = [s.owner, s.op, s.client, s.worker, s.party];
  const reg = at(plan, "PredgeAgentValidatorV2", op), job = at(plan, "AgentJobV2", client), bond = at(plan, "PredgeValidatorBondV2", op);
  const arb = at(plan, "PredgeRefundArbiterV2", op), mock = at(plan, "MockRefundProtocolV2", client), settle = at(plan, "PredgeSettlementV2", client);
  const now = async () => (await provider.getBlock("latest")).timestamp;
  const ESCROW = 10n ** 15n;
  const output = Buffer.from("predge v2 fork e2e output");
  const OUT = "0x" + output.toString("hex");
  const E = sha256(output), X = h("not the expected output");
  const commit = (expected, salt) => keccak256(coder.encode(["bytes32", "bytes32"], [expected, salt]));
  // The CLIENT fixes the expected output in the job's specHash (Olympix 5.1.1): spec = bond.specHashFor(commit(E, salt)).
  const newJob = async (n, escrow = ESCROW) => {
    const salt = h(`predge/v2-fork/salt/${n}/${Date.now()}`);
    const spec = await bond.specHashFor(commit(E, salt));
    await send(`job.createJob #${n}`, job.createJob(await addr(worker), bond.target, spec, (await now()) + 7 * 86400, { value: escrow }));
    return { id: await job.jobCount(), spec, salt };
  };
  const stake = async (j, escrow = ESCROW, label = "bond.stakeAndCommit") => {
    const need = await bond.requiredBond(escrow);
    return send(label, bond.stakeAndCommit(j.spec, commit(E, j.salt), j.id, { value: need }));
  };

  // ---------------- honest path ----------------
  const digest = h(`predge/v2-fork/1/${Date.now()}`);
  await send("registry.validationRequest", reg.validationRequest(op.address, 1n, "ipfs://v2-fork", digest));
  const req1 = await reg.requestHashFor(1n, digest);
  const j1 = await newJob(1);
  await stake(j1);
  await send("job.submit (bytes, sha256 on-chain)", job.connect(worker).submit(j1.id, E, OUT));
  if (!(await job.getJob(j1.id)).hashedOnChain) throw new Error("deliverable was not hashed on-chain");
  await send("bond.recordScore(100) completes the job", bond.recordScore(j1.spec, 100, E, j1.salt, h("verdict")));
  if (Number((await job.getJob(j1.id)).state) !== 3) throw new Error("job not Completed by the bond");
  await send("registry.validationResponse", reg.validationResponse(req1, 100, "ipfs://v2-fork/verdict", h("verdict"), "predge/v2-fork"));
  if (await bond.wouldSlash(j1.spec)) throw new Error("honest verdict is slashable");
  await mustRevert("challenge of an honest verdict", "VerdictHonest", async () => bond.connect(party).challenge.staticCall(j1.spec));
  if ((await job.credit(await addr(worker))) !== ESCROW) throw new Error("provider is not credited the escrow");
  await send("job.withdraw (provider pulls payout)", job.connect(worker).withdraw());
  if ((await job.credit(await addr(worker))) !== 0n) throw new Error("provider credit not cleared");
  await send("settlement.payForRoute", settle.payForRoute(h("/v2/route"), "v2-fork", { value: 1000n }));
  await send("settlement.withdraw (owner)", settle.connect(owner).withdraw(await addr(owner)));

  // ---------------- attacks that worked on v1 ----------------
  // H-01: verdict before submission, then wait the window out and reclaim.
  const j2 = await newJob(2);
  await mustRevert("Olympix 5.1.1 operator commits a value the client did not fix", "CommitmentNotBound", async () => bond.stakeAndCommit.staticCall(j2.spec, commit(X, j2.salt), j2.id, { value: ESCROW }));
  await stake(j2);
  await mustRevert("H-01 recordScore before the provider submits", "NotSubmitted", async () => bond.recordScore.staticCall(j2.spec, 100, E, j2.salt, ZeroHash));
  await mustRevert("H-01 reclaim without a verdict", "NotScored", async () => bond.reclaim.staticCall(j2.spec));
  // H-02: commit after the deliverable exists / swap the revealed value / provider copies public data.
  const j3 = await newJob(3);
  await send("job.submit (j3, wrong output)", job.connect(worker).submit(j3.id, X, "0x"));
  await mustRevert("H-02 commit after submission", "NotOpen", async () => bond.stakeAndCommit.staticCall(j3.spec, commit(E, j3.salt), j3.id, { value: ESCROW * 2n }));
  const j4 = await newJob(4);
  await stake(j4);
  const staked = await bond.stakes(j4.spec);
  if (staked.expected !== ZeroHash) throw new Error("expected is visible on-chain before the reveal");
  await send("job.submit (j4, provider submits the public commitment)", job.connect(worker).submit(j4.id, staked.commitment, "0x"));
  await send("bond.recordScore(0) honest fail", bond.recordScore(j4.spec, 0, E, j4.salt, h("fail")));
  await mustRevert("H-02 honest fail is not slashable", "VerdictHonest", async () => bond.connect(party).challenge.staticCall(j4.spec));
  // M-02: a false pass is slashed to the harmed client; the challenger gets nothing.
  const j5 = await newJob(5);
  await stake(j5);
  await send("job.submit (j5, wrong output)", job.connect(worker).submit(j5.id, X, "0x"));
  await send("bond.recordScore(100) FALSE pass", bond.recordScore(j5.spec, 100, E, j5.salt, h("lie")));
  if (!(await bond.wouldSlash(j5.spec))) throw new Error("false pass not slashable");
  await send("bond.challenge by a stranger", bond.connect(party).challenge(j5.spec));
  const clientCredit = await bond.credit(await addr(client)), partyCredit = await bond.credit(await addr(party));
  if (clientCredit < ESCROW || partyCredit !== 0n) throw new Error(`slash routing wrong: client ${clientCredit} challenger ${partyCredit}`);
  attacks.push({ attack: "M-02 slash pays the harmed client, challenger earns 0", blockedBy: "routing" });
  await send("bond.withdraw (client)", bond.connect(client).withdraw());
  // Olympix 5.2.2: an operator that stays silent on delivered work forfeits its bond to the provider.
  const j6 = await newJob(6);
  await stake(j6);
  await send("job.submit (j6, bytes, operator stays silent)", job.connect(worker).submit(j6.id, E, OUT));

  // M-03: expiry. An unsubmitted job can be refunded after expiry; the bond is released with no verdict.
  await increaseTime(7 * 86400 + 1);
  await mustRevert("late submit after expiry", "PastDeadline", async () => job.connect(worker).submit.staticCall(j2.id, E, "0x"));
  await send("job.claimRefund (expired, never submitted)", job.connect(party).claimRefund(j2.id));
  await send("bond.release (no verdict was given)", bond.connect(party).release(j2.spec));
  await send("job.claimRefund (j6, silent evaluator)", job.connect(party).claimRefund(j6.id));
  const workerBondBefore = await bond.credit(await addr(worker));
  await send("bond.release (j6, forfeited to the provider)", bond.connect(party).release(j6.spec));
  if ((await bond.credit(await addr(worker))) - workerBondBefore !== (await bond.requiredBond(ESCROW))) throw new Error("silent operator's bond not forfeited to the provider");
  attacks.push({ attack: "Olympix 5.2.2 silence on delivered work is free", blockedBy: "bond forfeited to provider" });
  await send("bond.withdraw (provider gets the forfeited bond)", bond.connect(worker).withdraw());

  // reclaim of the honest stake after its window
  await send("bond.reclaim (j1, anyone, after window)", bond.connect(party).reclaim(j1.spec));
  await send("bond.withdraw (staker)", bond.withdraw());

  // ---------------- arbiter ----------------
  const payer = await addr(party), payee = await addr(worker);
  const mkPayment = async (amount) => {
    await send("mock.recordPayment", mock.recordPayment(payer, payee, amount, (await now()) + 40 * 86400));
    return mock.paymentCount();
  };
  const p1 = await mkPayment(ESCROW);
  const EV = h("payer evidence"), CEV = h("payee counter evidence");
  await mustRevert("H-03 stranger files evidence for someone else's payment", "NotAParty", async () => arb.connect(client).fileEvidence.staticCall(p1, EV));
  await send("arbiter.fileEvidence (payer)", arb.connect(party).fileEvidence(p1, EV));
  await mustRevert("H-03 operator cites a non-party", "NotAParty", async () => arb.rule.staticCall(p1, await addr(client), EV, 1, { value: ESCROW }));
  await send("arbiter.rule(Refund)", arb.rule(p1, payer, EV, 1, { value: await arb.requiredBond(ESCROW) }));
  if ((await mock.payments(p1)).refunded) throw new Error("refund executed inside rule()");
  attacks.push({ attack: "H-03 refund does not execute inside rule()", blockedBy: "optimistic window" });
  await mustRevert("H-03 finalize inside the window", "WindowOpen", async () => arb.connect(client).finalize.staticCall(p1));
  await send("arbiter.dispute (harmed payee)", arb.connect(worker).dispute(p1, CEV));
  await send("arbiter.resolve(Release) overturns", arb.connect(owner).resolve(p1, 2));
  if ((await mock.payments(p1)).refunded) throw new Error("overturned refund executed");
  if ((await arb.credit(payee)) !== (await arb.requiredBond(ESCROW))) throw new Error("operator bond not paid to the harmed payee");
  await send("arbiter.withdraw (payee gets the operator bond)", arb.connect(worker).withdraw());
  const p2 = await mkPayment(ESCROW);
  await send("arbiter.fileEvidence (payer, p2)", arb.connect(party).fileEvidence(p2, EV));
  await send("arbiter.rule(Refund, p2)", arb.rule(p2, payer, EV, 1, { value: await arb.requiredBond(ESCROW) }));
  await increaseTime(86401);
  await send("arbiter.finalize (undisputed, after window)", arb.connect(client).finalize(p2));
  if (!(await mock.payments(p2)).refunded) throw new Error("undisputed refund did not execute");
  await send("arbiter.withdraw (operator bond back)", arb.withdraw());

  // ---------------- access ----------------
  await mustRevert("non-owner setOperator", "NotOwner", async () => reg.connect(op).setOperator.staticCall(await addr(client)));
  await mustRevert("non-owner transferOwnership", "NotOwner", async () => bond.connect(client).transferOwnership.staticCall(await addr(client)));
  return { steps, attacks };
}
