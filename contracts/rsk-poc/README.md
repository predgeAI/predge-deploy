# Rootstock testnet PoC: no-objection release (IBUKI / Re.RISE)

**Status: testnet only (chainId 31). `PredgeNoObjectionEvaluator` is new code and has not been externally audited.**
`AgentJobV2` is the unchanged v2.1 source from `contracts/v2`; only a new instance with a longer evaluation window was deployed.

## Why an adapter
The PoC follows a Japanese demolition contract (B2B sample from Re.RISE): if the client raises no written objection within
10 days of receiving the complete evidence package, the work is accepted and paid. `AgentJobV2` alone refunds the client when
the evaluator is silent, which is the opposite rule. `PredgeNoObjectionEvaluator` is the evaluator the job names. It holds no
funds and has no owner:

- the client commits a hash of the evidence checklist when creating the job;
- the contractor submits a manifest of file hashes (only hashes go on-chain);
- after the objection period, anyone can call `releaseOnSilence`: it checks the manifest is complete against the checklist
  (exact item count, no empty item) and completes the job to the contractor;
- the client can `object` inside the period, which puts the job on hold;
- only the reviewer can `resolve` an objected job (pay or refund);
- if nobody decides before the job's evaluation window ends, `AgentJobV2`'s default refunds the client.

Out of scope, as agreed on the RootstockCollective forum (#30/#31): staged milestones, judging photos, bonds.

## Deployed on Rootstock testnet (09.11.2026, Sourcify exact_match)

| Contract | Address | Setting |
|---|---|---|
| AgentJobV2 (first IBUKI job) | `0x5eAe41E4a082e6F5fDda067535757927c2716844` | 24-day evaluation window |
| PredgeNoObjectionEvaluator (first IBUKI job) | `0xc1e3259a417FD06781941cA973dB6e58274DA683` | 10-day objection period |
| AgentJobV2 (smoke) | `0x9BEef8D301D2C536Fb7c2A62e0156bbCA6A07A56` | 15-minute window |
| PredgeNoObjectionEvaluator (smoke) | `0xa7004a660Cc1b62bb66a36B8BE591166639CCf15` | 3-minute objection period |

Smoke on the live testnet (17/17 checks): job A, no objection, released after the period and withdrawn; job B, objected,
release refused while on hold, non-reviewer could not resolve, reviewer refunded, client withdrew. Records and tx hashes:
`deployments/rsk-poc/`. The reviewer is a Predge test wallet; a different reviewer means redeploying one evaluator.

## Run
- Tests: `FOUNDRY_CONFIG=foundry-v2.toml forge test --match-contract NoObjection` (16 tests).
- Deploy + smoke: `scripts/rsk-poc/poc.mjs` (`--fork` for an anvil fork dry run; `--broadcast` with `CONFIRM_TESTNET=rootstock-testnet`).
  Keys are read from `~/.predge-rsk/` and are never committed.
