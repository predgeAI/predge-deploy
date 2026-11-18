// The keeper. Every entry point it calls is permissionless and pays only the party the contract decides,
// so its key needs nothing but gas. It looks for jobs that can move and moves them.
import { Contract } from "ethers";
import { chainNow, JobState, RulingStatus } from "./chain.mjs";

/** What can happen to this job right now, or null. Pure, so it is also the keeper's dry run. */
export function nextAction(job, ruling, now) {
  if (job.state !== JobState.Funded) return null;
  const s = ruling.status;
  if (s === RulingStatus.Ruled && now >= ruling.ruledAt + ruling.window) return "settle";
  if (s === RulingStatus.Finalized || s === RulingStatus.Overturned) return "settle";
  if (s === RulingStatus.Disputed && now >= ruling.expiresAt) return "expire";
  if (s === RulingStatus.None || s === RulingStatus.Voided) {
    if (!job.delivered && now > job.deliverBy) return "refundAfterDeadline";
    if (job.delivered && now >= job.releaseAt) return "releaseAfterBackstop";
  }
  return null;
}

/** One pass over all jobs. With `signer` null it reports and sends nothing. */
export async function keeperPass({ provider, escrow, arbiter }, signer, log = () => {}) {
  const now = await chainNow(provider);
  const last = await escrow.nextJobId();
  const done = [];
  for (let id = 1n; id < last; id++) {
    const job = await escrow.jobs(id);
    if (job.state !== JobState.Funded) continue;
    const action = nextAction(job, await arbiter.rulings(id), now);
    if (!action) continue;
    if (!signer) {
      done.push({ id, action, dryRun: true });
      log(`job ${id}: would call ${action}`);
      continue;
    }
    const target = action === "expire" ? new Contract(arbiter.target, arbiter.interface, signer) : new Contract(escrow.target, escrow.interface, signer);
    const tx = await target[action](id);
    await tx.wait();
    done.push({ id, action, tx: tx.hash });
    log(`job ${id}: ${action} ${tx.hash}`);
  }
  return done;
}
