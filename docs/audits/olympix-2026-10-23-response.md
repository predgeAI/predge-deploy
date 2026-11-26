> Published 26 Nov 2026 exactly as sent to Olympix on 24 Oct 2026. RootstockCollective grant thread t/1009 (post #28) refers to this document. The frozen audit commit for that grant is `013ad4c`.

# Predge v2 contracts: response to the Olympix BugPoCer scan

**Scan:** BugPoCer full scan of `predgeAI/predge-deploy` at commit `c47ed42` (branch `v2/contracts`), 23 Oct 2026. 2 High, 3 Medium, 12 Low (17 issues, 37 sites).
**Response date:** 23 Oct 2026, updated 24 Oct 2026 (option (a) for 5.1.2, PR merged)
**Fixes:** branch `fix/olympix-2026-10-23`, PR [predgeAI/predge-deploy#5](https://github.com/predgeAI/predge-deploy/pull/5) into `v2/contracts` (merged 24 Oct 2026, merge commit `013ad4c`; option (a) in `f38c4b6`).

Thank you for the report. We read every finding against the code, ran each of the five Foundry PoCs, and reproduced all of them (8 of 8 PoC tests fail on `c47ed42` exactly as described). Where you were right we say so and fixed it; where the behaviour is a documented choice we cite the design note. We do not dispute any finding outright; one partial disagreement (remedy proposed in 5.2.2-b) is noted inline. Update 24 Oct: 5.1.2 is now fixed (option (a), see below), so our earlier disagreement on its severity is withdrawn.

**Deployment status, stated plainly.** Our context document said v2 was not deployed. That was wrong: the scanned code (`c47ed42`) is deployed on Arc and Base (deployed 20 Oct 2026, owner a temporary EOA, `bondBps = arbiterBondBps = 0`). The contracts are not upgradeable, so the deployed instances carry the confirmed findings below until a redeployment. No redeployment has been made yet; the fixed set (v2.1) is prepared for redeployment on Arc and Base at new addresses, after which the scanned instances are marked deprecated.

## Summary

| ID | Title | Severity | Our status | Fix / reason |
|---|---|---|---|---|
| 5.1.1 | Operator-chosen expected value makes verdicts unslashable | High | Confirmed, fixed | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): client binds `expected` in the specHash; only on-chain-hashed bytes count as delivered |
| 5.1.2 | Validator bond not collateralised against escrow | High | Confirmed, fixed (24 Oct) | [`f38c4b6`](https://github.com/predgeAI/predge-deploy/commit/f38c4b6): `recordScore` reverts `VerdictContradictsEvidence` on any verdict that contradicts the on-chain evidence, so no false verdict can be recorded at any bond size |
| 5.2.1 | Refund ruling timeline not bound to releaseTimestamp | Medium | Confirmed, fixed (a, b, d); c acknowledged | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): `rule` requires `releaseTimestamp > now + window + RESOLUTION_TIMEOUT` for both directions |
| 5.2.2 | Operator silence on a submitted job is free; bond fully returned | Medium | Confirmed, fixed | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): `release` forfeits the bond to the provider if the job was submitted and never scored |
| 5.2.3 | Operator acting as client can leave the provider unpaid | Medium | Confirmed, fixed | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): `ClientIsOperator` in `stakeAndCommit` and `recordScore`; Sybil variant covered by 5.1.1 / 5.2.2 fixes |
| 5.3.1 | Arbiter bond returned on finalize gives no collusion deterrent | Low | Acknowledged by design | Optimistic arbiter; slash needs a dispute. v2-design §1 "Arbiter court of last resort", "Slash goes to the harmed party" |
| 5.3.2 | Unresponsive operator lets payment default to release | Low | Acknowledged by design | The Refund Protocol's own default without an arbiter ruling; the Safe rotates a dead operator. v2-design §1 roles |
| 5.3.3 | Validation request hash squattable by any agent NFT holder | Low | Confirmed, fixed | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): `requestHash` now includes `agentId` |
| 5.3.4 | Client can name itself evaluator in createJob | Low | Confirmed, fixed | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): `createJob` rejects evaluator == client or == provider |
| 5.3.5 | Client-chosen expiredAt locks operator bond without limit | Low | Acknowledged by design | Operator's own capital, operator decides whether to stake. v2-design §5 "an operator-set cap on job duration" (out of scope) |
| 5.3.6 | Cross-contract unit mismatch, bond sized on foreign amount | Low | Acknowledged by design (deployment gate) | v2-design §1 "Refund Protocol interface is ours", "Native units" |
| 5.3.7 | Irreversible submit without verdict-path check | Low | Acknowledged by design (mitigated) | v2-design §1 "Timeout policy"; providers can check `stakes(specHash)`; 5.2.2 fix now compensates silence on a bound stake |
| 5.3.8 | Operator rotation strands in-flight verdicts | Low | Confirmed, fixed | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): NatSpec corrected; a stranded stake now forfeits to the provider (5.2.2 fix) |
| 5.3.9 | No upper bound on minBond in _setParams | Low | Acknowledged by design | Owner-only, reversible liveness lever, as stated in our context validation (report p. 17) |
| 5.3.10 | Response not bound to requested validator | Low | Confirmed, fixed | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): the responding operator is recorded as `validator` |
| 5.3.11 | Slash depends on harmed party monitoring, unpaid, short window | Low | Acknowledged by design (moot for the validator bond after 5.1.2 fix; still applies to the arbiter) | v2-design §1 "Slash goes to the harmed party ... no bounty for third-party watchers"; §5 "Third-party challenger rewards" |
| 5.3.12 | Unbounded owner parameter forwarded to Refund Protocol | Low | Confirmed, fixed | [`78c6142`](https://github.com/predgeAI/predge-deploy/pull/5/commits/78c6142): lockup must be in `(challengeWindow + RESOLUTION_TIMEOUT, 365 days]` |

Totals: 10 confirmed and fixed, 7 confirmed and acknowledged by design, 0 disputed, 0 duplicates at issue level (overlaps between 5.2.3, 5.1.2-a, 5.2.2 and 5.3.8 are noted per finding).

## Findings

### 5.1.1 Operator-chosen expected value makes verdicts unslashable (High): confirmed, fixed
You are right. `expected` was chosen by the operator alone and the job accepted a claimed hash with no bytes, so a colluding operator and provider could make a false pass "honest" at any `bondBps` (`PredgeValidatorBondV2.sol` L154-177, L257-260 and `AgentJobV2.sol` L119-121 at `c47ed42`). Our stated property "at full bond a colluding operator and provider cannot profit" was false, and our fuzz test only covered a mismatching deliverable.
Fix: the client now fixes `expected` at `createJob`, since a bonded job's `specHash` must equal `bond.specHashFor(keccak256(abi.encode(expected, salt)))` (domain separated by chain and bond address), and `stakeAndCommit` reverts `CommitmentNotBound` otherwise. "Delivered" now means the bytes were hashed on-chain (`hashedOnChain`) and equal `expected`, so a leaked `expected` submitted as a bare hash no longer passes (since 24 Oct `recordScore` itself refuses such a pass, see 5.1.2). Regression tests: `OlympixRegressions.t.sol` `test_5_1_1_*`, invariant `invariant_stakeCommitsToClientValue`. Residual: the client defines the acceptance test; a provider should verify `(expected, salt)` against the specHash before working.

### 5.1.2 Validator bond not collateralised against escrow (High): confirmed, fixed (24 Oct 2026)
Initially acknowledged as an owner-set parameter (`bondBps = 0`). The owner has since chosen to remove the dependency on bond size altogether (option (a)): after the 5.1.1 fix both inputs of the acceptance test are on-chain at `recordScore` (the sha256 the job computed from the submitted bytes, and the `expected` the client committed in the specHash), so `recordScore` now requires `score == 100` exactly when `hashedOnChain && deliverable == expected` and reverts `VerdictContradictsEvidence` otherwise. A colluding operator and provider can no longer record a false pass (or a false fail) at any bond size, including the shipped `bondBps = 0`. The challenge path became unreachable and was removed (`challenge`, `wouldSlash`, `reclaim`, the dispute window); the bond is returned with the verdict and now only prices silence (5.2.2). Tests: `testFuzz_5_1_2_falsePassImpossibleAtShippedParams`, `testFuzz_noFalseVerdictCanBeRecorded`, `testFuzz_passIffOnChainHashMatches`, `testFuzz_collusionCannotExtractEscrowAtAnyBond`, `test_5_1_1_leakedExpectedWithoutBytesCannotPass`, invariant `invariant_everyRecordedVerdictIsTrue`.

### 5.2.1 Refund ruling timeline not bound to releaseTimestamp (Medium): confirmed, fixed (a, b, d); c acknowledged
Confirmed, PoC reproduced: `rule` only required `releaseTimestamp > now + window`, and only for Refund rulings (`PredgeRefundArbiterV2.sol` L211), so a free last-second dispute could push `resolve` past release, where `refundByArbiter` reverts and takes the overturn with it.
Fix: `rule` now requires `releaseTimestamp > now + window + RESOLUTION_TIMEOUT` for both directions, so the latest possible `expiresAt` is before release and both `finalize` and `resolve` can always execute the refund. `setLockupSeconds` is bounded to match (5.3.12). Tests: `test_5_2_1_*`, `test_rule_needsLockupBeyondWindowAndResolution`. Cost: refund-arbitrated payments need a lockup above `window + 14 days`. Sub-finding c (a disputed ruling the owner never resolves is voided and the bond returns to the staker) is the documented liveness backstop (v2-design §1 "Arbiter court of last resort is the Safe ... Liveness").

### 5.2.2 Operator silence on a submitted job is free (Medium): confirmed, fixed
You are right that silence cost the operator nothing and the provider got nothing (`release`, L241-248). Fix: if the job was submitted and expired without a verdict, `release` now credits the bond to the provider (new terminal status `Forfeited`); if the provider never submitted, the bond still returns to the staker. The escrow itself still goes to the client on timeout: that is the documented timeout policy (v2-design §1 "Timeout policy"; `AgentJobV2` NatSpec), and paying the provider by default would let a silent or bribed evaluator pay for unverified work. So we did not adopt the remedy implied by the 5.2.2-b PoC (provider receives the escrow); the provider receives the bond. Tests: `test_5_2_2_*`, `invariant_silenceAfterSubmissionForfeits`.

### 5.2.3 Operator acting as client can leave the provider unpaid (Medium): confirmed, fixed
Confirmed: only `provider == operator` was blocked. `stakeAndCommit` and `recordScore` now also revert `ClientIsOperator` (the second check covers a rotation onto the client's key). An operator using a separate client address is covered by the other fixes: it cannot pick an unmatchable `expected` beyond what the client fixed (5.1.1), a false fail on real bytes is refused by `recordScore`, and silence forfeits the bond (5.2.2). The loss beyond the bond at `bondBps < 10000` is 5.1.2. Tests: `test_5_2_3_operatorAsClientRefused`, `test_stake_operatorCannotBeClient`, `test_score_rotatedOperatorCannotBeClient`.

### 5.3.1 Arbiter bond returned on finalize gives no collusion deterrent (Low): acknowledged by design
Correct description of the optimistic model: an undisputed ruling finalizes and returns the bond. The NatSpec and v2-design §1 state that a wrong ruling is punished only if the harmed party disputes inside the window and the Safe agrees, and `arbiterBondBps = 0` is an owner decision. The arbiter only drives the demo `MockRefundProtocolV2` on our chains.

### 5.3.2 Unresponsive operator lets payment default to release (Low): acknowledged by design
True: without a ruling the Refund Protocol's own default (release at the end of the lockup) applies. The arbiter is optional and optimistic by design; a dead or unresponsive operator key is replaced by the owner via `setOperator` (v2-design §1, roles and rotation).

### 5.3.3 Validation request hash squattable by any agent NFT holder (Low): confirmed, fixed
Confirmed for a registry configured with a permissionless identity registry (our deployments use `address(0)`, so only the operator can request there). Fix: `requestHashFor(agentId, digest) = keccak256(abi.encode(chainid, this, agentId, digest))`, so a holder of agent B cannot pre-claim agent A's request. Test: `test_request_digestCannotBeSquattedAcrossAgents`.

### 5.3.4 Client can name itself evaluator in createJob (Low): confirmed, fixed
`createJob` now reverts `EvaluatorNotIndependent` when the evaluator is the client or the provider, and the "INDEPENDENT" wording in the NatSpec was replaced with what the check actually guarantees (it cannot detect two addresses of one party). Test: `test_createJob_evaluatorNotClientOrProvider`.

### 5.3.5 Client-chosen expiredAt locks operator bond without limit (Low): acknowledged by design
Correct; the operator's own capital is locked until the client's expiry. The operator chooses whether to stake and the NatSpec says to read `expiredAt` first; an on-chain cap on job duration is listed as out of scope in v2-design §5.

### 5.3.6 Cross-contract unit mismatch, bond sized on foreign amount (Low): acknowledged by design (deployment gate)
Correct, and already a deployment gate in v2-design §1: `IRefundProtocolV2.paymentInfo` is our interface, a production Refund Protocol needs a reviewed adapter, and all amounts are native wei. An adapter must report `amount` in native wei; we will not wire the arbiter to anything else.

### 5.3.7 Irreversible submit without verdict-path check (Low): acknowledged by design, mitigated
The provider's risk of working for an evaluator that never answers is the documented timeout policy (v2-design §1). A provider can check before submitting that `stakes(specHash)` is `Committed` for its `jobId`; with the 5.2.2 fix, silence on such a stake now pays the provider the bond. Keying stakes by `jobId` is a larger change we have not made.

### 5.3.8 Operator rotation strands in-flight verdicts (Low): confirmed, fixed
Confirmed: our "never strands" NatSpec on `Operated` was only true for the bond credit. The NatSpec now states that an in-flight verdict needs the old commitment's preimage, and the 5.2.2 fix means a stake stranded by rotation forfeits to the provider instead of returning to the operator. Test: `test_5_3_8_rotationWithoutPreimageForfeitsToProvider`.

### 5.3.9 No upper bound on minBond in _setParams (Low): acknowledged by design
Owner-only and reversible; it affects only new stakes and rulings (existing ones keep their bond). We stated this as a deliberate emergency lever during context validation (report p. 17, "owner (setParams minBond/bondBps)").

### 5.3.10 Response not bound to requested validator (Low): confirmed, fixed
`validationResponse` now records `msg.sender` as `validator`, so the canonical `ValidationResponse` event and `getValidationStatus` name the key that answered after a rotation. Test: `test_response_afterRotationNamesTheResponder`.

### 5.3.11 Slash depends on harmed-party monitoring, unpaid, short window (Low): acknowledged by design
Documented trade-off: the slash goes to the harmed party and never the caller, so self-challenge and front-running earn nothing, at the cost of no watcher bounty (v2-design §1, M-02; §5 "Third-party challenger rewards"). `MIN_WINDOW` is a floor for the owner; the shipped window is 24 hours.

### 5.3.12 Unbounded owner parameter forwarded to Refund Protocol (Low): confirmed, fixed
`setLockupSeconds` now requires `challengeWindow + RESOLUTION_TIMEOUT < lockup <= 365 days` and emits `LockupForwarded`. Test: `test_setLockupSeconds_bounded`.

## Mutation testing

Your run on `c47ed42`: 203 of 211 mutants killed (96.2%), 8 survived. We re-ran each survivor against our suite.

| Mutant | Result |
|---|---|
| Bond L133 `job_ == address(0)` to `!=` | Killed by our suite at `c47ed42`, but only in `setUp()` (every deployment reverts), which a runner counting named test functions does not see. Now also killed by `ConstructorGuardsTest.test_bond_constructorGuards` |
| Arbiter L155 `refundProtocol_ == address(0)` to `!=` | Same as above; now killed by `test_arbiter_constructorGuards`, `test_arbiter_constants` |
| Arbiter L316 `bondBps_ > MAX_BPS` to `<` | Same as above; now killed by `test_arbiter_constructorGuards` (deploys at 500 and 10000) |
| AgentJob L76 `evaluationWindow_ == 0` to `!=` | Same as above; now killed by `test_job_constructorGuard`, `test_bond_constructorGuards` |
| Arbiter L94 `RESOLUTION_TIMEOUT = 14 days` to `15 days` | A real gap: no test pinned the value. Now killed by `test_arbiter_constants`, `test_rule_needsLockupBeyondWindowAndResolution`, `test_setLockupSeconds_bounded` |
| Registry L159, L172, L196 `Validation storage v` to `memory` | Equivalent mutants: all three are in `view` functions (`getValidationStatus`, `commitLeadTime`, `getSummary`) that only read `v`; a memory copy returns the same values and only costs more gas. Not killable by a behavioural test |

After the changes, all 5 killable survivors are killed by named tests, and the 3 equivalent mutants are justified above, which gives 208 of 208 non-equivalent mutants killed on the scanned mutant set. Our own one-line mutation smoke over the fixed code (`scripts/mutate-v2.mjs`): 244 of 247 mutants killed (23 Oct; after option (a), the bond alone: 56 of 58, the 2 survivors equivalent: a comment line and `>`/`>=` in `requiredBond`); the 3 survivors are equivalent (`>` to `>=` in `requiredBond` of the bond and the arbiter, where both branches return the same value when `scaled == minBond`, and a mutation inside a comment).

## Verification

- Full v2 Foundry suite on the merged branch (24 Oct, with option (a)): 152 of 152 tests pass, with both the default and the `ci` profile (fuzz 5000 runs, invariants 512 x 100) (unit, fuzz 1000 runs, 2 invariant suites).
- `forge coverage` on `contracts/v2`: 100% lines, statements, branches and functions (398/398 lines, 124/124 branches after option (a) removed the challenge path).
- The five original PoCs, run unchanged against the fixed code, now stop at their first step (`CommitmentNotBound` or `LockupTooShort`); the adapted versions in `OlympixRegressions.t.sol` replay the remaining attack path and pass.
- Local fork end-to-end (`node deploy.mjs --chain base --set v2 --fork`, local anvil fork, nothing broadcast): 30 read-only checks, 49 honest-path transactions, 16 attack sequences blocked (Base and Arc forks, 24 Oct), including 5.1.1, 5.2.2 and false pass / false fail attempts, which revert.

## Changes that affect integrators

- A job evaluated by `PredgeValidatorBondV2` must use `specHash = bond.specHashFor(keccak256(abi.encode(expected, salt)))`, chosen by the client. The registry's `requestHash` is no longer used as the specHash.
- A pass is only valid when the provider submits the output bytes (`hashedOnChain`). A bare claimed hash counts as not delivered.
- `PredgeAgentValidatorV2.requestHashFor` now takes `(agentId, digest)`.
- Refund-arbitrated payments need a lockup longer than `challengeWindow + 14 days`.
