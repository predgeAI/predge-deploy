// Smoke checks. `readOnly` runs on a live chain: reads config and eth_calls only, so it costs
// nothing and does not touch the deployer's nonce. `e2e` runs on a local fork only: it drives
// every contract through its honest path with throwaway anvil accounts.
import { Contract, keccak256, toUtf8Bytes, ZeroHash } from "ethers";
import { compile, maskImmutables } from "./compile.mjs";
import { waitReceipt } from "./chains.mjs";

const at = (plan, name, runner) => new Contract(plan.find((s) => s.name === name).address, compile(name).abi, runner);
const h = (s) => keccak256(toUtf8Bytes(s));

export async function readOnly(provider, plan, deployer) {
  const checks = [];
  const ok = (name, cond, detail) => { checks.push({ check: name, ok: !!cond, detail }); if (!cond) throw new Error(`smoke failed: ${name} (${detail})`); };
  const op = plan[0].args[0];

  for (const s of plan) {
    const code = await provider.getCode(s.address);
    const c = s.compiled;
    ok(`${s.name} runtime == compiled`, maskImmutables(code, c.immutableReferences) === maskImmutables(c.deployedBytecode, c.immutableReferences), s.address);
  }
  const v = at(plan, "PredgeAgentValidator", provider);
  ok("validator.owner == deployer", (await v.owner()) === deployer, await v.owner());
  ok("validator.validator == operator", (await v.validator()) === op, await v.validator());
  const st = await v.getValidationStatus(h("predge/smoke/none"));
  ok("validator.getValidationStatus(unknown) is empty", st[0] === "0x0000000000000000000000000000000000000000", String(st[0]));

  const job = at(plan, "AgentJob", provider);
  ok("job.jobCount readable", (await job.jobCount()) >= 0n, String(await job.jobCount()));
  // createJob is payable; with value 0 it must revert ZeroEscrow, which proves the call path.
  let reverted = false;
  try { await job.createJob.staticCall(deployer, op, h("x"), { from: deployer }); } catch (e) { reverted = /ZeroEscrow|0x/.test(String(e.data ?? e.message)); }
  ok("job.createJob(value 0) reverts ZeroEscrow (eth_call)", reverted, "");

  const bond = at(plan, "PredgeValidatorBond", provider);
  ok("bond.owner == deployer", (await bond.owner()) === deployer, await bond.owner());
  ok("bond.validator == operator", (await bond.validator()) === op, await bond.validator());
  ok("bond.job == AgentJob", (await bond.job()) === job.target, await bond.job());
  ok("bond.disputeWindow", (await bond.disputeWindow()) === BigInt(plan[2].args[2]), String(await bond.disputeWindow()));
  ok("bond.wouldSlash(unknown) == false", (await bond.wouldSlash(h("predge/smoke/none"))) === false, "");

  const settle = at(plan, "PredgeSettlement", provider);
  ok("settlement.owner == deployer", (await settle.owner()) === deployer, await settle.owner());

  const arb = at(plan, "PredgeRefundArbiter", provider);
  const mock = at(plan, "MockRefundProtocol", provider);
  ok("arbiter.owner == deployer", (await arb.owner()) === deployer, await arb.owner());
  ok("arbiter.operator == operator", (await arb.operator()) === op, await arb.operator());
  ok("arbiter.refundProtocol == mock", (await arb.refundProtocol()) === mock.target, await arb.refundProtocol());
  ok("mock.arbiter == arbiter", (await mock.arbiter()) === arb.target, await mock.arbiter());
  ok("arbiter.challengeWindow/minBond", (await arb.challengeWindow()) === BigInt(plan[5].args[2]) && (await arb.minBond()) === BigInt(plan[5].args[3]), "");
  ok("arbiter.rulingOf(0) empty", (await arb.rulingOf(0))[3] === 0n, "");
  return checks;
}

/** Full honest-path run on a fork. `signers` are unlocked anvil accounts; `opSigner` is the operator. */
export async function e2e(provider, plan, opSigner, [client, worker, party], increaseTime) {
  const steps = [];
  const send = async (label, p) => { const tx = await p; const r = await waitReceipt(provider, tx.hash); if (r.status !== 1) throw new Error(`e2e ${label} reverted`); steps.push({ step: label, gasUsed: Number(r.gasUsed) }); return r; };
  const op = await opSigner.getAddress();
  const v = at(plan, "PredgeAgentValidator", opSigner), job = at(plan, "AgentJob", client), bond = at(plan, "PredgeValidatorBond", opSigner);
  const arb = at(plan, "PredgeRefundArbiter", opSigner), mock = at(plan, "MockRefundProtocol", provider), settle = at(plan, "PredgeSettlement", client);
  const spec = h(`predge/fork-e2e/${Date.now()}`), deliverable = h("deliverable-v1");

  await send("job.createJob", job.createJob(await worker.getAddress(), op, spec, { value: 10n ** 15n }));
  const jobId = await job.jobCount();
  await send("job.submit", job.connect(worker).submit(jobId, deliverable, "0x"));
  await send("validator.validationRequest", v.connect(client).validationRequest(op, 1n, "ipfs://predge-fork-e2e", spec));
  await send("validator.validationResponse", v.validationResponse(spec, 100, "ipfs://predge-fork-e2e/verdict", h("verdict"), "predge/fork-e2e"));
  const st = await v.getValidationStatus(spec);
  if (Number(st[2]) !== 100) throw new Error("validator did not record score 100");
  await send("bond.stakeAndCommit", bond.stakeAndCommit(spec, deliverable, jobId, { value: 10n ** 15n }));
  await send("bond.recordScore", bond.recordScore(spec, 100));
  if (await bond.wouldSlash(spec)) throw new Error("honest verdict is slashable");
  let honest = false;
  try { await bond.connect(party).challenge.staticCall(spec); } catch { honest = true; }
  if (!honest) throw new Error("challenge of an honest verdict did not revert");
  await send("job.complete", at(plan, "AgentJob", opSigner).complete(jobId, h("verdict"), "0x"));

  const pid = 7n, evidence = h("evidence");
  await send("arbiter.fileEvidence", arb.connect(party).fileEvidence(pid, evidence));
  await send("arbiter.rule(Refund)", arb.rule(pid, await party.getAddress(), evidence, 1, { value: await arb.minBond() }));
  if (!(await mock.refunded(pid))) throw new Error("mock refund protocol not called");
  if (await arb.wouldSlash(pid)) throw new Error("honest ruling is slashable");

  await send("settlement.payForRoute", settle.payForRoute(h("/v1/settlement-risk"), "fork-e2e", { value: 1000n }));
  await send("settlement.withdraw", at(plan, "PredgeSettlement", opSigner).withdraw(op));

  await increaseTime(86401);
  await send("bond.reclaim (after window)", bond.reclaim(spec));
  await send("arbiter.reclaim (after window)", arb.reclaim(pid));
  return steps;
}
