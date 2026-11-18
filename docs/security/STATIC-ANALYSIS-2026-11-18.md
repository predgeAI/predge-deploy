# Predge v2.1 contracts: static analysis, 18 Nov 2026

This is a tool-assisted internal review, not a third-party audit. No contract source was changed and nothing was deployed.

## Scope

| | |
|---|---|
| Repo / commit | `predgeAI/predge-deploy`, branch `v2/contracts` at `ae5488d` |
| Deployed set | `2026-10-23-v2.1`: `AgentJobV2`, `PredgeAgentValidatorV2`, `PredgeValidatorBondV2`, `PredgeSettlementV2`, `PredgeRefundArbiterV2`, `MockRefundProtocolV2`, plus `access/PredgeAccess.sol`, `access/PullCredit.sol`, `interfaces/IAgentJobV2.sol` |
| Source match | `sha256` of every deployed source file equals the `sourceSha256` in `deployments/v2/celo.json`. Runtime bytecode on chain was already checked against the compiler output when the set was deployed (`smoke` in each deployment record). |
| Also scanned, not deployed | `adapters/CircleRefundProtocolAdapter.sol`, `interfaces/ICircleRefundProtocol.sol`, `mocks/MockCircleRefundProtocol.sol`, `mocks/MockUSDC.sol` |
| Size (cloc 1.96) | 753 SLOC in the deployed set (8 files), 1,053 SLOC in `contracts/v2` overall (13 files) |
| Compiler | solc 0.8.26, optimizer 200 runs, EVM `cancun` (the same settings the deployment used) |

## Tools and commands

| Tool | Version | Command |
|---|---|---|
| Slither | 0.11.6 (latest on PyPI, installed in a throwaway venv) | `slither contracts/v2/<File>.sol --compile-force-framework solc --solc solc-0.8.26 --solc-args "--optimize --optimize-runs 200 --evm-version cancun" --json <out>`, run once per top-level contract |
| Aderyn | 0.6.8 (latest GitHub release) | `FOUNDRY_CONFIG=foundry-v2.toml aderyn . --src contracts/v2` (88 detectors) |
| Foundry | forge 1.8.5 | `FOUNDRY_CONFIG=foundry-v2.toml forge test` and `forge coverage --report summary --ir-minimum` |
| cloc | 1.96 | `cloc --by-file --include-lang=Solidity contracts/v2` |

## Results at a glance

- **No High or Medium issue in the deployed contracts.** Each tool finding was triaged by hand. Every one is either a false positive or an intended design choice that is documented in the source.
- **Tests:** 166 of 166 pass across 18 suites. That covers unit, fuzz (1,000 runs) and invariant suites (256 runs × depth 64, about 16,000 handler calls per invariant suite, 0 reverts), plus regression tests for every Olympix and self-audit finding.
- **Coverage of the deployed contracts:**

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| AgentJobV2.sol | 100% (66/66) | 100% (86/86) | 100% (19/19) | 100% (9/9) |
| PredgeAgentValidatorV2.sol | 96.9% (63/65) | 97.3% (73/75) | 100% (20/20) | 100% (9/9) |
| PredgeRefundArbiterV2.sol | 100% (114/114) | 100% (156/156) | 100% (36/36) | 100% (15/15) |
| PredgeSettlementV2.sol | 100% (13/13) | 100% (14/14) | 100% (4/4) | 100% (4/4) |
| PredgeValidatorBondV2.sol | 100% (76/76) | 99.1% (113/114) | 100% (29/29) | 100% (11/11) |
| access/PredgeAccess.sol | 100% (24/24) | 100% (23/23) | 100% (6/6) | 100% (7/7) |
| access/PullCredit.sol | 100% (16/16) | 100% (16/16) | 100% (3/3) | 100% (4/4) |
| mocks/MockRefundProtocolV2.sol | 100% (24/24) | 100% (27/27) | 100% (7/7) | 100% (5/5) |
| adapters/CircleRefundProtocolAdapter.sol (not deployed) | 100% (31/31) | 95.3% (41/43) | 80% (8/10) | 100% (6/6) |

The two lines in `PredgeAgentValidatorV2` that the tests never reach are the `try/catch` path of an ERC-8004 identity registry. That path is disabled on every deployment (`identityRegistry = 0`).

## Findings and triage

TP = true positive, FP = false positive. "By design" means the tool flagged real behaviour that the contract intends and documents.

| # | Tool / detector | Location | Verdict | Severity | Rationale / action |
|---|---|---|---|---|---|
| 1 | Aderyn `reentrancy-state-change` (High) | Arbiter L193, L213; Bond L176, L214 | FP | none | The "external call" is `refundProtocol.paymentInfo` / `job.getJob`. Both are declared `view`, so they compile to `STATICCALL` and cannot change state or re-enter. Both targets are `immutable` and set at deployment. |
| 2 | Aderyn `reentrancy-state-change` (High) | Adapter L69-70 (not deployed) | FP | none | These are `view` calls inside the one-time `bind`, which only the deployer can call. |
| 3 | Aderyn `reentrancy-state-change` (High) | MockCircleRefundProtocol L62, L97 | FP / out of scope | none | A test mock that is never deployed. |
| 4 | Aderyn `eth-send-unchecked-address` (High) | PullCredit L24 `withdrawTo` | By design | none | A caller can only send **its own** credit, and the zero address is rejected. Choosing the recipient is the feature: it lets a blocklisted or contract recipient withdraw at all. Credit is zeroed before the call (checks-effects-interactions). |
| 5 | Slither `unused-return` (Medium) | Arbiter L193 `fileEvidence` | FP | none | Only payer and payee are needed there. Amount and release time are read and used in `rule` (L213). |
| 6 | Slither `unused-return` (Medium) | Adapter L98 (not deployed) | FP | none | Only the `refunded` flag is needed. |
| 7 | Slither `timestamp` (Low), 13 instances | Job, Arbiter, Bond, Mock | By design | Info | The deadlines span hours to days (evaluation window 3 days, challenge window ≥ 1 h, resolution 14 days). A validator's few-second timestamp skew cannot change an outcome in a meaningful way. |
| 8 | Slither / Aderyn missing zero-check | PredgeAccess L38 `transferOwnership` | By design | Info | Nominating `address(0)` cancels a pending nomination, as the NatSpec documents. Ownership can only move when the nominee calls `acceptOwnership`, so a typo can never lose ownership. |
| 9 | Slither missing zero-check | Validator constructor `identityRegistry_` | By design | Info | Zero is a valid value meaning "no registry, only the operator may request". |
| 10 | Slither `low-level-calls` | PullCredit L46, Settlement L40 | By design | Info | Native-value transfer with the return value checked. Both transfers follow checks-effects-interactions. |
| 11 | Aderyn `centralization-risk` (Low), 7 instances | `onlyOwner` functions | TP (governance) | Low | Covered in the next section. The key point is that the owner cannot move escrowed or bonded funds. Action: move ownership to a multisig (planned for Celo first, see below). |
| 12 | Aderyn `large-numeric-literal`, `literal-instead-of-constant`, `unused-public-function` | Bond, Arbiter | Style | Info | `10_000` (bps), scores `0`/`100`, and the public `verdictFor`, which is intentionally public for off-chain callers. No change to deployed code. |
| 13 | Aderyn `missing-inheritance`, `costly-loop`, `require-revert-in-loop`, `state-change-without-event`, `unsafe-erc20-operation`, `uninitialized-local-variable` | mocks only | Out of scope | none | Test mocks. |
| 14 | Slither `naming-convention` | ICircleRefundProtocol | Style | Info | The name mirrors Circle's own ABI and has to match. |

Manual review on top of the tools (state machine, rounding, rotation, and pull-payment accounting): no new issue. The invariant suites assert the following after every random call sequence, including operator rotations: each contract is solvent (its balance is at least its escrowed or bonded total plus `totalCredit`), and every recorded verdict matches the on-chain evidence. The suites also check that `totalEscrowed` and `totalBonded` equal the sum of the live positions, that state is write-once and monotonic, and that no funds can be locked permanently.

## What the owner key can and cannot do

The grant reviewers raised "one key owns contracts that hold escrowed funds". These are the facts from the source:

- **`AgentJobV2`, the only contract that escrows user funds, has no owner, no admin, no upgrade path and no mutable parameter.** No key can move, freeze or redirect an escrow. Funds leave only through `complete`/`reject` by the job's evaluator, or through `claimRefund` to the client after a timeout.
- `PredgeValidatorBondV2` holds only the operator's own bond. The owner can change the bond floor and bps for **future** stakes and can rotate the operator. It cannot touch a posted bond or a verdict. `recordScore` reverts on any verdict that contradicts the on-chain evidence.
- `PredgeRefundArbiterV2` holds only the operator's ruling bonds. The owner resolves **disputed** rulings within 14 days, sets bounded parameters (not retroactive), and forwards a bounded recipient lockup. On every v2.1 chain the arbiter is wired to `MockRefundProtocolV2`, which holds no funds.
- `PredgeSettlementV2` collects Predge's own pay-per-call revenue. The owner withdraws it, and that is its only function.
- `PredgeAgentValidatorV2` holds no value.
- Ownership uses a two-step hand-over (`transferOwnership` then `acceptOwnership`) and has no `renounceOwnership`.

Planned change: ownership on Celo moves from a single key to a 2-of-2 Safe. Other chains move to a Safe plus a timelock once escrowed value there exceeds $10k, or before they accept third-party funds above that amount.

## Earlier reviews

- **Self-audit, 20 Oct 2026** (manual review and Slither, Aderyn, Mythril, Semgrep, Foundry, Gambit mutation testing) on the v1/v2.0 set: 3 High, 5 Medium, 7 Low. All were addressed in the v2 redesign (see the README, section "v2"). Regression tests in `test/foundry-v2/V1Findings.t.sol` and `Pocs.t.sol` pin each fix.
- **Olympix BugPoCer, 23 Oct 2026**, on the Arc v2.0 set (`c47ed42`): the confirmed findings were fixed in v2.1 (PR #5), and `test/foundry-v2/OlympixRegressions.t.sol` pins them. The v2.0 set is deprecated and held no funds.
- No independent third-party audit has been done yet. One is planned before escrowed value grows past the threshold above.

## Reproduce

```bash
git clone https://github.com/predgeAI/predge-deploy && cd predge-deploy && git checkout v2/contracts
git submodule update --init
FOUNDRY_CONFIG=foundry-v2.toml forge test
FOUNDRY_CONFIG=foundry-v2.toml forge coverage --report summary --ir-minimum
python3 -m venv .venv && .venv/bin/pip install slither-analyzer==0.11.6
.venv/bin/slither contracts/v2/PredgeRefundArbiterV2.sol --compile-force-framework solc --solc-args "--optimize --optimize-runs 200 --evm-version cancun"
FOUNDRY_CONFIG=foundry-v2.toml aderyn . --src contracts/v2
```
