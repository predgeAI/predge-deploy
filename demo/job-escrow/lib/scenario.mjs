// The steps of a job, shared by the local demo and the Arc testnet CLI.
import { Contract, ethers } from "ethers";
import { requestVerdict } from "./api.mjs";
import { evidenceHashOf, specHashOf } from "./verdict.mjs";
import { executePlan, planVerdict } from "./relayer.mjs";

/** A logical name, so the signed spec does not carry a local port. The transport is `sellerUrl`. */
export const JOB_ENDPOINT = "https://seller.demo.invalid/v1/report";

export const jobSpec = (extra = {}) => ({
  endpoint: JOB_ENDPOINT,
  method: "GET",
  expected_content_type: "application/json",
  required_fields: ["rows"],
  non_empty_fields: ["rows"],
  ...extra,
});

const as = (contract, signer) => new Contract(contract.target, contract.interface, signer);

/** Buyer agent: approve, then lock the payment. `amount` is in token units: 10_000_000n is 10 USDC. */
export async function payForJob(w, { spec, amount, deliverIn = 3600n }) {
  const { buyer, refundTo, seller } = w.wallets;
  const usdc = as(w.usdc, buyer);
  await (await usdc.approve(w.escrow.target, amount)).wait();
  const now = BigInt((await w.provider.getBlock("latest")).timestamp);
  const tx = await as(w.escrow, buyer).pay(seller.address, amount, refundTo.address, specHashOf(spec), now + deliverIn);
  const receipt = await tx.wait();
  const log = receipt.logs.map((l) => { try { return w.escrow.interface.parseLog(l); } catch { return null; } }).find((p) => p?.name === "JobPaid");
  return { id: log.args.id, payTxHash: tx.hash, amount, spec };
}

/** Buyer agent calls the seller's API and keeps what came back as the delivery record. */
export async function callSeller(sellerUrl, path, { reportLatency = true } = {}) {
  const started = Date.now();
  const res = await fetch(`${sellerUrl}${path}`);
  const body = await res.text();
  const delivery = { status: res.status, headers: { "content-type": res.headers.get("content-type") ?? "" }, body };
  if (reportLatency) delivery.latency_ms = Date.now() - started;
  return delivery;
}

/** The payer's side (`refundTo`) files the hash of what it received. `rule` reverts without filed evidence. */
export async function fileDeliveryEvidence(w, jobId, delivery, party = w.wallets.refundTo) {
  const tx = await as(w.arbiter, party).fileEvidence(jobId, evidenceHashOf(delivery.body));
  await tx.wait();
  return tx.hash;
}

export function verdictRequest(w, job, delivery) {
  return {
    job: job.spec,
    delivery,
    payment: {
      tx_hash: job.payTxHash,
      network: `eip155:${w.chainId}`,
      asset: w.usdc.target,
      // A number because the API requires one; 6dp, so no float error reaches the signed string.
      amount_usd: Number(ethers.formatUnits(job.amount, 6)),
      payer: w.wallets.refundTo.address,
      payee: w.wallets.seller.address,
    },
    buyer_id: "predge-demo-buyer-agent",
    merchant_id: "predge-demo-seller-agent",
  };
}

export const askForVerdict = (w, job, delivery) => requestVerdict(w.apiBase, w.apiKey, verdictRequest(w, job, delivery));

/** The relayer: all off-chain checks, then the two operator transactions. */
export async function relay(w, jobId, verdict) {
  const plan = await planVerdict(w, jobId, verdict);
  if (plan.action === "human_review") return { plan };
  return { plan, txs: await executePlan({ escrow: w.escrow, arbiter: w.arbiter, operator: w.wallets.operator }, plan) };
}
