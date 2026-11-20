# Predge v2.1 contracts: pre-audit review for Olympix

## 1. Summary

| | |
|---|---|
| Project | Predge v2.1 contracts (`predgeAI/predge-deploy`, `contracts/v2`) |
| Date | 21 Nov 2026 |
| Review level | Max: Critical, High, Medium and Low (Informational is listed too) |
| Commit reviewed | `f38c4b67a05fbe3e66cfa579083da089db57692f`, the source deployed on Arc mainnet as the v2.1 set |
| Branch with the fixes | `audit/arc-studio-2026-11-21` |
| Solidity compiler | solc 0.8.26 (`0.8.26+commit.8a97fa7a`), optimizer on, 200 runs, EVM `cancun`, the same settings as the deployment |
| Framework | Foundry (`FOUNDRY_CONFIG=foundry-v2.toml`) |
| Out of scope | `contracts/v2/mocks`, the v1 contracts in `contracts/*.sol`, tests, scripts, `lib/`, `foundry-lib/` |

**The deployed contracts are immutable.** Nothing on any chain was changed by this review, and nothing was deployed. The two fixes below exist only as source on this branch. They form a new revision that has not been deployed. Every deployed v2.1 contract still runs the "before" source.

Result in one line: the review found **no Critical, High or Medium issue** in the reviewed source. It found 19 items: 2 fixed, 4 left Open because they need an owner decision, 10 accepted as documented design, and 3 Slither false positives.

### Files reviewed

| Path | SHA-256 before the review (`f38c4b6`) | SHA-256 after the fixes |
|---|---|---|
| `contracts/v2/AgentJobV2.sol` | `c83bd1c9ce4e8643b39246586619b7a12e203653b3f03386de03ab58b58c4a9a` | `c83bd1c9ce4e8643b39246586619b7a12e203653b3f03386de03ab58b58c4a9a` (unchanged) |
| `contracts/v2/PredgeAgentValidatorV2.sol` | `188c8c4f4d75ca748cad006a4b30a825d2bc9e9725e42085685000e3ee0232dd` | `da022e7e7b0220d9107669beef83482554b01e165406af9aa8d275e3d1739d2d` |
| `contracts/v2/PredgeRefundArbiterV2.sol` | `b5dc07973805879660216a2047ce1471f6a05abeb49c07466efc77e0c5f56bcf` | `7d75ab318784514b5ca25e25597c6c3f06913359642ef77b97553d09983ca487` |
| `contracts/v2/PredgeSettlementV2.sol` | `fb87e5ef6756eb261c854ccf1f711234a2e657718aecb2e2d116557aa4ab84b7` | `fb87e5ef6756eb261c854ccf1f711234a2e657718aecb2e2d116557aa4ab84b7` (unchanged) |
| `contracts/v2/PredgeValidatorBondV2.sol` | `0b84858a48a63548f0b889ca451587c6e57c81cf3b239e6521188f58aa8c694d` | `0b84858a48a63548f0b889ca451587c6e57c81cf3b239e6521188f58aa8c694d` (unchanged) |
| `contracts/v2/access/PredgeAccess.sol` | `719f9a0baf81313155db73189a9c080a9695a8eee46609633adbc84a89b0e637` | `719f9a0baf81313155db73189a9c080a9695a8eee46609633adbc84a89b0e637` (unchanged) |
| `contracts/v2/access/PullCredit.sol` | `fbe75c615d819f41cf2381f18aae77683d4c85cb31926cf853f70247c92241ef` | `fbe75c615d819f41cf2381f18aae77683d4c85cb31926cf853f70247c92241ef` (unchanged) |
| `contracts/v2/interfaces/IAgentJobV2.sol` | `2a5304efe8419a71373227820b725dbbb65c1828e239ef43ab998d46a8b6892f` | `2a5304efe8419a71373227820b725dbbb65c1828e239ef43ab998d46a8b6892f` (unchanged) |

Hashes were taken with `shasum -a 256`, which gives the same output as `sha256sum`.

### Behavior changes made by the fixes

- **F-01, `PredgeRefundArbiterV2.rule`:** a payment whose `payer` is `address(0)` is now refused with `UnknownPayment`. Before the fix, only a zero `payee` was refused. Nothing else changes. On the deployed set this path cannot be reached anyway, because `MockRefundProtocolV2.recordPayment` already rejects a zero payer.
- **F-02, `PredgeAgentValidatorV2._isAgentOwner`:** some identity registries are broken: they have no code, return fewer than 32 bytes, or return a word that is not a clean address. When a caller other than the operator meets one of these, the call now reverts with `NotAuthorized` instead of reverting with no data. Who is authorized is unchanged: the operator, or the exact address `ownerOf` returns. Deployed validators are built with `identityRegistry = 0`, so this path is switched off there.

No other change was made to any contract. Both fixes change the runtime bytecode of their contract. The source of each fixed contract therefore no longer matches its deployed bytecode, which is expected for a new revision.

## 2. Findings

Severity for review findings is this review's own assessment. For Slither findings it is Slither's impact rating, and the status column gives the triage. Line numbers refer to the reviewed commit `f38c4b6`.

| ID | Severity | Source | Title | File and line | Status | Fix or reason |
|---|---|---|---|---|---|---|
| F-01 | Low | review | `rule` accepts a payment whose payer is `address(0)`. Nobody can dispute a Release ruling on it, and an overturn would credit the bond to `address(0)` forever | `PredgeRefundArbiterV2.sol:214` | Fixed | `rule` now reverts `UnknownPayment` when payer or payee is zero |
| F-02 | Low | review | `_isAgentOwner` try/catch does not catch a registry with no code or with malformed return data, so the decode reverts with no reason | `PredgeAgentValidatorV2.sol:211-218` | Fixed | Replaced with `staticcall` plus a length check and a full-word comparison. A broken answer now means "not the owner" |
| F-03 | Low | review | If the Refund Protocol rejects `refundByArbiter`, the owner cannot overturn a Release ruling into a Refund, so a wrong ruling cannot be slashed. An undisputed Refund ruling also cannot be finalized. The ruling ends Voided and the bond goes back to the staker | `PredgeRefundArbiterV2.sol:286, 321` | Open | The fix would change how a failed refund settles the bond, which touches economics |
| F-04 | Low | review | Once a payment has any ruling, including a Voided one, it can never be ruled again and no party can file new evidence. One void ends on-chain arbitration for that payment | `PredgeRefundArbiterV2.sol:192, 211` | Open | Allowing a re-rule after a void changes the ruling state machine |
| F-05 | Low | review | After `expiresAt`, an undisputed ruling can be either finalized (the refund runs) or expired (nothing runs). Whoever calls first decides, so the payee can void an unfinalized Refund ruling | `PredgeRefundArbiterV2.sol:259-264, 291-301` | Open | Documented in NatSpec. Closing `finalize` at `expiresAt` changes verdict semantics |
| F-06 | Low | review | Disputes are free. If the owner does not resolve within `RESOLUTION_TIMEOUT` (14 days), the ruling is voided, nothing runs, and the operator keeps its bond | `PredgeRefundArbiterV2.sol:244-254, 291-301` | Accepted risk | Documented trust model: the owner Safe is the court of last resort |
| F-07 | Low | review | Centralization: the owner sets bounded parameters, rotates the operator, resolves disputes, forwards lockups and withdraws settlement revenue. `resolve` does not stop the owner from deciding a payment it is a party to | `PredgeRefundArbiterV2.sol:167, 174, 269`; `PredgeValidatorBondV2.sol:141`; `access/PredgeAccess.sol:85`; `PredgeSettlementV2.sol:36` | Accepted risk | The owner cannot move `AgentJobV2` escrow, a posted bond or a recorded verdict. The intended owner is a Safe multisig |
| F-08 | Low | review | The client picks `expiredAt` with no upper bound. If the provider never submits, the client's escrow and the operator's bond stay locked until `expiredAt`, which can be centuries away | `AgentJobV2.sol:100`; `PredgeValidatorBondV2.sol:178` | Open | Capping job duration is a new rule. For now the operator must check `expiredAt` off-chain before staking (documented) |
| F-09 | Low | review | If the operator is rotated while a stake is Committed and the new key is not given `(expected, salt)`, the new key cannot score. The job times out, the client is refunded and the bond is forfeited to the provider | `access/PredgeAccess.sol:85`; `PredgeValidatorBondV2.sol:203-230` | Accepted risk | Documented (Olympix 5.3.8): rotate with no stake in flight, or hand the preimages over |
| F-10 | Informational | review | Stakes are keyed by `specHash`, which is public. Anyone can open other jobs with the same `specHash`, and only one of them can ever be bonded | `PredgeValidatorBondV2.sol:171-179` | Accepted risk | The operator names the `jobId` and checks it with the client off-chain. A copied job cannot take the stake |
| F-11 | Informational | review | A job that names the bond as evaluator but is never staked cannot be completed. The provider's work is unpaid and the client is refunded at the timeout | `AgentJobV2.sol:91-112`; `PredgeValidatorBondV2.sol:203-210` | Accepted risk | Documented timeout policy: providers should check that a stake exists before working |
| F-12 | Informational | review | When an identity registry is set, the agent owner can record an `(agentId, digest)` request first, with a `requestURI` it chooses. The operator's identical request then reverts | `PredgeAgentValidatorV2.sol:108-127` | Accepted risk | Only the agent's own owner can do this, and the digest still binds the content. The path is off on every deployment (`identityRegistry = 0`) |
| F-13 | Informational | review | `getSummary` rounds the average response down | `PredgeAgentValidatorV2.sol:208` | Accepted risk | Integer arithmetic, consistent with ERC-8004 `uint8` scores |
| F-14 | Informational | review | `PredgeSettlementV2.withdraw` with a zero balance succeeds and emits `Withdrawn(to, 0)` | `PredgeSettlementV2.sol:36-42` | Accepted risk | Harmless and owner-only. Reverting would change behavior for no security gain |
| F-15 | Medium | Slither `unused-return` | `fileEvidence` ignores `amount` and `releaseTimestamp` from `paymentInfo` | `PredgeRefundArbiterV2.sol:193` | False positive | Only payer and payee are needed there. Amount and release time are read and enforced in `rule` (L213-224) |
| F-16 | Low | Slither `timestamp` (11 instances) | Deadlines compare against `block.timestamp` | `AgentJobV2.sol:100, 123, 158, 160, 178`; `PredgeRefundArbiterV2.sol:192, 224, 248, 262, 273, 294`; `PredgeValidatorBondV2.sol:178` | Accepted risk | The windows run from hours to days (job evaluation window, challenge window of at least 1 h, 14-day resolution). Seconds of validator skew cannot change an outcome in a meaningful way. Boundaries are tested exactly |
| F-17 | Low | Slither `missing-zero-check` | `transferOwnership` accepts `address(0)` | `access/PredgeAccess.sol:38` | False positive | By design, nominating zero cancels a pending nomination. Ownership only moves when the nominee calls `acceptOwnership`, so the owner can never become zero |
| F-18 | Low | Slither `missing-zero-check` | The constructor accepts `identityRegistry_ = 0` | `PredgeAgentValidatorV2.sol:93` | False positive | Zero is the documented "operator only" mode |
| F-19 | Informational | Slither `low-level-calls` | Low-level calls in `PullCredit._withdraw` and `PredgeSettlementV2.withdraw`, plus the new `staticcall` from the F-02 fix (`PredgeAgentValidatorV2.sol:216` after the fix) | `access/PullCredit.sol:46`; `PredgeSettlementV2.sol:40` | Accepted risk | Every result is checked. Value sends follow checks-effects-interactions, with the credit zeroed before the call. The `staticcall` cannot change state |

Slither summary. Before the fixes, the 5 per-contract runs reported 21 results, 16 of them unique: 11 timestamp, 2 low-level-calls, 2 missing-zero-check and 1 unused-return. After the fixes there are 17 unique results. The only new one is the F-02 `staticcall`, an Informational low-level-calls result counted under F-19. Slither reported no reentrancy, arbitrary-send, uninitialized-state or other High-impact result.

The existing write-up `docs/security/STATIC-ANALYSIS-2026-11-18.md` (branch `docs/static-analysis-2026-11-18`, commit `ae5488d`) reports the same Slither results. Its triage of rows 5, 7, 8, 9 and 10 holds and is reused for F-15 to F-19. Its Aderyn rows, and its rows on the adapter and mocks, cover files outside this scope or tools that were not re-run here (see section 5).

## 3. Tests

Command, run from the project root:

```bash
FOUNDRY_CONFIG=foundry-v2.toml forge test -j 4
```

Result: **180 passed, 0 failed, 0 skipped** across 20 suites. Fuzz tests use 1,000 runs. Invariant suites use 256 runs at depth 64, with 0 reverts. Before the fixes, the suite on `f38c4b6` passed 152 of 152. The 28 new tests are in `ArcStudioReview.t.sol`.

The tests for the two fixes were also run against the original source. The four tests that pin the fixed behavior (`test_F01_ruleRejectsPaymentWithZeroPayer` and the three `test_F02_*NotAuthorized` tests) fail there, and they pass after the fix.

| Test file | Passed / failed | Finding IDs covered |
|---|---|---|
| `test/foundry-v2/ArcStudioReview.t.sol` (new) | 28 / 0 | F-01 (2 tests), F-02 (5, including 1 fuzz), F-03 (2), F-04, F-05, F-06, F-07 (2), F-08, F-09, F-10, F-11, F-12, F-13, F-14, F-15, F-16 (2), F-17, F-18, F-19 (2) |
| `test/foundry-v2/AgentJobV2.t.sol` | 21 / 0 | F-11 and F-16 (job lifecycle and deadlines), F-19 (pull payments) |
| `test/foundry-v2/PredgeValidatorBondV2.t.sol` | 26 / 0 | F-08, F-09, F-10 and F-16 (stake and score rules, rotation) |
| `test/foundry-v2/PredgeRefundArbiterV2.t.sol` | 24 / 0 | F-03 (`finalize` reverts when the protocol reverts, then `expire` voids), F-05, F-06, F-07 and F-16 |
| `test/foundry-v2/Misc.t.sol` | 29 / 0 | F-02 (identity-registry path), F-12 (request keyed to its agent), F-13 (`getSummary`), F-17 (cancelling a nomination) and F-19 (failed settlement withdraw reverts) |
| `test/foundry-v2/OlympixRegressions.t.sol` | 12 / 0 | Prior Olympix BugPoCer findings 5.1.1, 5.1.2, 5.2.1, 5.2.2, 5.2.3 and 5.3.8 (5.3.3, 5.3.4 and 5.3.10 are pinned in `Misc.t.sol` and `AgentJobV2.t.sol`). F-09 overlaps with 5.3.8 |
| `test/foundry-v2/Pocs.t.sol` | 15 / 0 | Prior self-audit PoCs (v1/v2.0). No new ID |
| `test/foundry-v2/V1Findings.t.sol` | 19 / 0 | Prior self-audit findings. F-09 (rotation) overlaps |
| `test/foundry-v2/ConstructorGuards.t.sol` | 4 / 0 | Constructor guards of job, bond and arbiter. No new ID |
| `test/foundry-v2/Invariants.t.sol` | 2 / 0 (2 invariant suites, 15 invariants) | Solvency, accounting, write-once state and no permanent lock. Supports F-16 and F-19 |
| `test/foundry-v2/Base.sol` | helper, no tests | |

## 4. Open items

Every finding not marked Fixed is listed here. The first four are **Open**: each needs a decision from the owner before any code change. The rest are accepted risks or false positives. They are listed so that you can confirm the acceptance.

**Open: a decision is needed**

- **F-03: a refund the Refund Protocol refuses blocks the slash.** *Risk:* if the operator rules Release wrongly and the payment can no longer be refunded (for example it was already released early, or the protocol is paused), the owner cannot overturn the ruling. The operator gets its bond back instead of losing it to the payer. *Decide:* should an overturn record the outcome and slash the bond even when the refund call fails, for example by catching the revert? That changes who ends up with the bond in this edge case.
- **F-04: one void ends arbitration for a payment.** *Risk:* if a ruling is voided because the owner stayed silent or the protocol reverted for a while, the payment can never be ruled again on-chain. *Decide:* should a Voided ruling reopen the payment for a new `rule`, and with what limit on the number of retries?
- **F-05: the race between `finalize` and `expire` after `expiresAt`.** *Risk:* if nobody finalizes a correct, undisputed Refund ruling within the 14 days after the window, the payee can call `expire` and the refund never happens. *Decide:* should `finalize` stay callable after `expiresAt` (current behavior) and `expire` apply only to Disputed rulings, or should the operator be expected to finalize promptly, as documented today?
- **F-08: no upper bound on job duration.** *Risk:* a client can set `expiredAt` decades ahead. If the provider never submits, the client's escrow and any operator bond are locked until then. *Decide:* should `createJob`, or `stakeAndCommit` only, enforce a maximum duration? Today it is an off-chain check by the operator.

**Accepted risk: please confirm**

- **F-06: free disputes and owner liveness.** *Risk:* the harmed party can always dispute at no cost. A silent owner then voids the ruling, so a slow Safe equals "no decision". *Confirm:* the Safe signers commit to resolving disputes within 14 days.
- **F-07: owner powers.** *Risk:* a compromised owner key could rotate the operator, change future bond sizes, resolve disputes its own way (including payments it is a party to), and withdraw settlement revenue. It cannot touch job escrow, posted bonds or recorded verdicts. The deployment records list a single owner address. This review did not check on-chain whether that address is a Safe. *Confirm:* that ownership is (or will be) a Safe multisig, as planned.
- **F-09: operator rotation with a stake in flight.** *Risk:* a rotation without handing over `(expected, salt)` forfeits the bond to the provider. *Confirm:* the operational rule "rotate only with no stake in flight, unless the key is compromised".
- **F-10: shared `specHash`.** *Risk:* only operator confusion. A copied job cannot take a stake that names another `jobId`. *Confirm:* the operator always takes the `jobId` from the client and checks the job before staking.
- **F-11: an unbonded job pays nobody.** *Risk:* a provider that works on a bond-evaluated job with no stake is never paid. *Confirm:* the documented guidance that providers check for a stake first.
- **F-12: the agent owner can pre-register a request.** *Risk:* only the agent's own owner can set a misleading `requestURI` for its own validation. The path is off on deployments. *Confirm:* keep it as is.
- **F-13: the summary average rounds down.** *Risk:* the displayed average can be up to 1 point low. *Confirm:* acceptable.
- **F-14: a zero-amount settlement withdraw.** *Risk:* none beyond a zero-amount event. *Confirm:* acceptable.
- **F-16: timestamp dependence.** *Risk:* a block producer can shift a deadline check by seconds. All windows are hours or days long. *Confirm:* acceptable.
- **F-19: low-level calls.** *Risk:* none found. Results are checked and follow checks-effects-interactions. *Confirm:* acceptable.

**False positive: nothing to decide**

- **F-15** (`unused-return`), **F-17** (`transferOwnership` zero check) and **F-18** (zero identity registry) are intended behavior, as explained in section 2.

## 5. Audit Provenance

| Step | Who or what produced it | Version | Date | Scope or commit | Notes |
|---|---|---|---|---|---|
| Manual security review, finding IDs F-01 to F-19, fixes, new tests and this document | AI review by Claude (Anthropic model Claude Opus 5.5, `claude-opus-5-5`) running in Claude Code, at the request of the Predge owner | n/a | 21 Nov 2026 | `f38c4b67a05fbe3e66cfa579083da089db57692f`, `contracts/v2` excluding `mocks` | No human auditor took part in this review. Findings are the model's own assessment and have not been independently verified |
| Static analysis | Slither | 0.11.6 (102 detectors), with solc 0.8.26 | 21 Nov 2026 | Same commit, then again after the fixes. One run per top-level contract: `slither contracts/v2/<File>.sol --compile-force-framework solc --solc solc-0.8.26 --solc-args "--optimize --optimize-runs 200 --evm-version cancun"` | Results are triaged in section 2 (F-15 to F-19) |
| Unit, fuzz and invariant tests | Foundry `forge` | 1.8.5 (`51a52c5`) | 21 Nov 2026 | `FOUNDRY_CONFIG=foundry-v2.toml forge test -j 4` | 152/152 before the fixes, 180/180 after |
| Prior context: internal static analysis | Predge internal, tool-assisted (Slither 0.11.6, Aderyn 0.6.8, forge coverage) | as stated in the document | 18 Nov 2026 | `ae5488d`, branch `docs/static-analysis-2026-11-18`, `docs/security/STATIC-ANALYSIS-2026-11-18.md` | Read, and its Slither triage was reused after this review's own Slither run. Aderyn was not re-run here |
| Prior context: automated scan | Olympix BugPoCer | n/a | 23 Oct 2026 | `c47ed42` (Arc v2.0 set) | Reported 2 High, 3 Medium and 12 Low. v2.1 (`f38c4b6`) contains the fixes. `OlympixRegressions.t.sol` pins them and all 12 of its tests pass. This review did not re-run BugPoCer |
| Independent third-party audit | none yet | | | | The Olympix audit this document prepares for will be the first |
