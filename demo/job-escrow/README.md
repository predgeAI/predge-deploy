# Predge Job Escrow

**DEMO ONLY. UNAUDITED. TESTNET ONLY. Do not put real funds through it.** The contract says so on chain (`DEMO_NOTICE`), and its constructor refuses every chain except local anvil (31337) and Arc testnet (5042002).

An agent pays USDC into escrow. Predge checks the delivery and signs a verdict. A relayer turns the verdict into a bonded ruling. After a one-hour challenge window a keeper settles it, and the money goes to the seller or back to the buyer with no further decision. Either harmed party can dispute inside the window.

## Run it

```bash
npm ci
git submodule update --init foundry-lib/forge-std
npm run demo:job-escrow        # local anvil, no keys, no network; exit 0 means every check passed
npm run demo:job-escrow:test   # Foundry suite, then the off-chain verdict tests
```

The local demo signs with a throwaway key through a stand-in for the verdict API, in the same format. `node demo/job-escrow/run.mjs --api live` calls `api.predge.io` with `PREDGE_KEY`.

For Arc testnet, see the top of `cli.mjs`. Every write needs `--broadcast` and `CONFIRM_TESTNET=arc-testnet`.

## How a job moves

| Step | Who | Call | Money |
|---|---|---|---|
| Pay | buyer agent | `escrow.pay(seller, amount, refundTo, specHash, deliverBy)` | into escrow |
| Deliver | seller | API response, plus `escrow.markDelivered` | |
| Evidence | a party | `arbiter.fileEvidence(id, sha256(body))` | |
| Verdict | anyone with a key | `POST /v1/verdicts` | |
| Rule | relayer, operator key | `escrow.recordVerdict`, then `arbiter.rule{value: bond}` | bond into arbiter |
| Dispute (optional) | harmed party, then owner | `arbiter.dispute`, `arbiter.resolve` | frozen |
| Settle | keeper, anyone | `escrow.settle(id)` | out, at once |

| Verdict | Direction |
|---|---|
| `delivered` | Release |
| `not_delivered` | Refund |
| `inconclusive` | no ruling; flagged for a human |

With no ruling, an undelivered job can be refunded by anyone after `deliverBy`. A delivered job goes to the seller at `releaseAt`, 16 days after payment by default.

## What ties a verdict to a job

The relayer checks all of this before it sends anything (`lib/verdict.mjs`, `lib/relayer.mjs`):

- the ed25519 signature, by a key in the published registry that is not revoked
- that `payload` rebuilds `canonical`; only signed fields are used
- `job_sha256` equals the job's on-chain `specHash`
- `payment_ref.tx_hash` is a successful transaction that emitted `JobPaid` for this job on this escrow
- network, payer (`refundTo`), payee and amount
- `delivery.body_sha256` is what one of the parties filed

On chain, `recordVerdict` allows one verdict per job and one job per verdict.

## What this does not prove

- **ed25519 is checked off chain.** The contract cannot verify it. On chain, trust rests on the operator key, its bond and the dispute path. `recordVerdict` is an audit trail and a replay guard, and the arbiter does not require it before `rule`.
- **A verdict is only as true as the evidence.** Predge did not observe the delivery, and the signed payload says so. A party that files false evidence is answered by a dispute, not by the signature.
- **The owner decides disputes.** In this demo the owner is a test key, not a Safe.
- **`markDelivered` is a claim.** A seller can make it falsely to close the deadline refund. The buyer then needs a ruling within about 47 hours, or the seller collects at the backstop.
- **The keeper matters.** A Refund ruling left unfinalized past `expiresAt` can be voided by anyone. If the job was marked delivered, the seller then collects at the backstop.
- **Payments are pushed.** A recipient that USDC refuses (blocklisted) makes the settlement revert. A refund then ends in a voided ruling.
- **This is not Circle's Refund Protocol**, and the verdict API still reports refunds as `recommendation_only`. This demo acts on a verdict; the API does not.

`PredgeRefundArbiterV2` is used unchanged, as a fresh instance with its own roles.
