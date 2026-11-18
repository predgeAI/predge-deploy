// The relayer: takes a signed verdict, checks it off chain, then carries it out with the operator key.
// It is the only place where an API verdict becomes an on-chain ruling. It needs the operator key and the
// bond in native gas; it never holds the verdict signing key.
import { Contract } from "ethers";
import { attestationHashOf, checkBinding, Direction, directionFor, verifyAttestation, VerdictRejected } from "./verdict.mjs";
import { JobState, RulingStatus } from "./chain.mjs";

const reject = (code, message) => {
  throw new VerdictRejected(code, message);
};

/** The verdict's `payment_ref.tx_hash` must really be the transaction that paid this job, on this escrow. */
async function requirePaymentTx(provider, escrow, jobId, txHash) {
  if (typeof txHash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(txHash)) reject("wrong_payment", `verdict names no valid tx hash (${txHash})`);
  const receipt = await provider.getTransactionReceipt(txHash);
  if (!receipt || receipt.status !== 1) reject("wrong_payment", `payment ${txHash} is not a successful transaction on this chain`);
  const address = (await escrow.getAddress()).toLowerCase();
  for (const l of receipt.logs) {
    if (l.address.toLowerCase() !== address) continue;
    const parsed = escrow.interface.parseLog(l);
    if (parsed?.name === "JobPaid" && parsed.args.id === BigInt(jobId)) return;
  }
  reject("wrong_payment", `payment ${txHash} did not pay job ${jobId}`);
}

/**
 * Everything that can be decided without sending a transaction. Returns the plan, or throws VerdictRejected.
 * `operator` is the arbiter-side identity and is only used for reads here.
 */
export async function planVerdict({ provider, escrow, arbiter, chainId, trustedKeys }, jobId, verdictResponse) {
  const attestation = verdictResponse?.attestation;
  const payload = verifyAttestation(attestation, trustedKeys);

  const job = await escrow.jobs(jobId);
  if (job.state !== JobState.Funded) reject("job_not_active", `job ${jobId} is not Funded`);
  const payTxHash = payload.payment_ref?.tx_hash;
  const { evidenceHash } = checkBinding(payload, {
    specHash: job.specHash,
    refundTo: job.refundTo,
    seller: job.seller,
    amount: job.amount,
    chainId,
    payTxHash,
  });
  await requirePaymentTx(provider, escrow, jobId, payTxHash);

  const direction = directionFor(payload);
  const attestationHash = attestationHashOf(attestation);
  const base = { jobId: BigInt(jobId), verdict: payload.verdict, verdictId: payload.verdict_id, reasonCodes: payload.reason_codes, attestationHash };
  if (direction === Direction.None) return { ...base, action: "human_review" };

  // Replay is checked here to keep a replay out of the mempool; recordVerdict refuses it on chain as well.
  const usedFor = await escrow.attestationJob(attestationHash);
  if (usedFor !== 0n && usedFor !== BigInt(jobId)) reject("replayed", `verdict was already used for job ${usedFor}`);
  const ruling = await arbiter.rulings(jobId);
  if (ruling.status !== RulingStatus.None) reject("replayed", `job ${jobId} already has a ruling`);
  const recorded = await escrow.verdicts(jobId);
  const alreadyRecorded = recorded.attestationHash !== `0x${"0".repeat(64)}`;
  if (alreadyRecorded && recorded.attestationHash !== attestationHash) reject("replayed", `job ${jobId} already has a different verdict`);

  // Cite the party whose filed evidence is the delivery the verdict actually judged.
  let evidenceFrom = null;
  for (const party of [job.refundTo, job.seller]) {
    if ((await arbiter.filedEvidence(jobId, party)) === evidenceHash) {
      evidenceFrom = party;
      break;
    }
  }
  if (!evidenceFrom) reject("evidence_not_filed", `neither party has filed ${evidenceHash} for job ${jobId}`);

  const [, , scaled] = await escrow.paymentInfo(jobId);
  return { ...base, action: "rule", direction, evidenceFrom, evidenceHash, bond: await arbiter.requiredBond(scaled), alreadyRecorded };
}

/** Carry out a plan. Safe to re-run after a crash between the two transactions. Returns tx hashes. */
export async function executePlan({ escrow, arbiter, operator }, plan) {
  const bound = (c) => new Contract(c.target, c.interface, operator);
  const txs = {};
  if (!plan.alreadyRecorded) {
    const tx = await bound(escrow).recordVerdict(plan.jobId, plan.attestationHash, plan.direction);
    await tx.wait();
    txs.record = tx.hash;
  }
  const tx = await bound(arbiter).rule(plan.jobId, plan.evidenceFrom, plan.evidenceHash, plan.direction, { value: plan.bond });
  await tx.wait();
  txs.rule = tx.hash;
  return txs;
}
