# predge-deploy

One command deploys the full Predge agent-settlement contract set to any EVM chain, with the
**same bytecode and the same addresses on every chain**.

```bash
npm install
node deploy.mjs --chain base            # dry run against the live chain: plan, addresses, nonce/balance, gas. Sends nothing.
node deploy.mjs --chain base --fork     # full deploy + smoke + end-to-end on a local anvil fork of Base mainnet
CONFIRM_MAINNET=base node deploy.mjs --chain base --broadcast   # the real deploy
```

## The set

Order is the deployer's nonce. Contract *i* is created at nonce *i*.

| Nonce | Contract | What it is | Canonical source |
|---|---|---|---|
| 0 | `PredgeAgentValidator` | ERC-8004 Validation-Registry-shaped validator with commit-before-outcome | predge-arc `0b48435` |
| 1 | `AgentJob` | ERC-8183 job escrow, Predge as the named evaluator | predge-arc `0b48435` |
| 2 | `PredgeValidatorBond` v2.1 | Validator bond; the dispute window runs from the verdict (audit fix F1) | predge-robinhood `bc57c52` = predge-arc `c0762ea` |
| 3 | `PredgeSettlement` | Pay-per-route receipts in the native token | predge-arc `6f29672` |
| 4 | `MockRefundProtocol` | Stand-in Refund Protocol for the arbiter (the same one Arc mainnet uses) | predge-arc `293bd70` |
| 5 | `PredgeRefundArbiter` v2 | Bonded refund arbiter; `rule()` needs the evidence filed on-chain first (audit fix F2) | predge-arc `95b723d` |

The compiler is solc 0.8.26 (`v0.8.26+commit.8a97fa7a`, npm `solc`), with the optimizer at 200 runs and `evmVersion` set to cancun.
These are the settings the existing audited deployments were built with. `npm test` compiles the set and compares it,
byte for byte (immutables masked), with the live code on Arc mainnet (bond v2.1, arbiter v2, mock, validator,
job), Arbitrum One (bond v2.1, settlement) and Monad mainnet (validator, bond, job). All 10 match. `scripts/probe-chains.mjs` runs
`PUSH0` and `MCOPY` with `eth_call` on every live chain, with an `INVALID` negative control. All 17 chains
execute the cancun opcodes this bytecode uses.

Constructor args are the same on every chain:

- operator/validator = the deployer address. It can be rotated later with `setValidator` or `setOperator`, and the addresses do not change.
- `disputeWindow` and `challengeWindow` = 86400 s.
- arbiter `minBond` = 0.001 native. The owner can change it per chain with `setParams`.

See `config/set.json`.

## Why nonce-synced CREATE and not CREATE2

The standard CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` exists on all 17 chains, but it cannot be used for this set as written.
Every owned contract sets `owner = msg.sender` in its constructor. Under CREATE2 that owner would be the proxy, and it would stay the proxy forever:

- `PredgeSettlement.withdraw` would lock the receipts with no way out;
- `setValidator` and `setOperator` could never be called;
- `setParams` and `setLockupSeconds` could never be called.

Fixing that means changing the audited sources to take an `owner_` argument. That gives new bytecode and requires a new audit.

So the tool gets the same property another way. It uses a **dedicated fresh deployer whose nonce is 0 on every chain** and creates the set in a fixed order.
CREATE addresses depend only on (deployer, nonce), so every chain gets the same addresses.
The tool enforces this:

- Before each step it checks the predicted address and the nonce.
- Code already at the predicted address is compared with the compiled runtime. If it matches, the step is skipped, so a run can be resumed. If it does not match, the run stops.
- If the deployer's nonce is higher than the step, the run stops: the key was used elsewhere and this chain can no longer get the canonical addresses.

**Never use the deployer key for anything else.** Not even a plain transfer out until every chain has the whole set.

Canonical addresses for deployer `0x5d016C1B4d7A42eB7c982da1Ae7fFdB958CFCAe9`:

| Contract | Address (every chain) |
|---|---|
| PredgeAgentValidator | `0x925767fdce6C819F027f55CC50464e3bCdfD2671` |
| AgentJob | `0xcBaB4a9FA4d756b4C5e2a18F055d2E0132CE7D1D` |
| PredgeValidatorBond | `0x800B5596a8540e752dE8f8a8AF99E927d139A643` |
| PredgeSettlement | `0x47BE8a7d461De505723a0Ac1d74982e53f8E412b` |
| MockRefundProtocol | `0xcaC30945CDF0F963f38972d939e111B87b80Cf79` |
| PredgeRefundArbiter | `0xb2972B4944Eec83946EB7B23D572AbE04F46E22c` |

## Commands

| Command | What it does | Touches a chain? |
|---|---|---|
| `npm run keygen` | Creates `~/.predge-deployer/deployer.json` (dir 0700, file 0600). Prints the address only. Refuses to overwrite an existing key. | no |
| `npm run chains [chain…]` | chainId, cancun opcodes, gas price, ERC-8004 registries, deployer nonce | read-only |
| `node deploy.mjs --chain X` | Dry run: plan, addresses, live `eth_estimateGas` per contract, balance and nonce checks | read-only |
| `node deploy.mjs --chain X --fork` | Starts `anvil --fork-url <live rpc>`, deploys at nonces 0..5, runs 23 read-only checks and a 13-tx honest path (job → validator request/response → bond stake/score → job complete → evidence → arbiter rule(Refund) → settlement pay/withdraw → +24h → bond and arbiter reclaim), then prices the gas with the live gas price + the L2 data fee. Writes `deployments/fork/X.json`. | local fork only |
| `npm run fork-all [chain…]` | The above for every chain, plus `deployments/fork/SUMMARY.json` | local forks only |
| `npm run funding -- --out <file.md>` | Funding table: fork gasUsed × live gas price + L2 data fee, +50%, USD | read-only |
| `CONFIRM_MAINNET=X node deploy.mjs --chain X --broadcast` | Real deploy, then source verification, then the read-only smoke checks. Writes `deployments/X.json`. | **yes** |

A broadcast needs both the `--broadcast` flag and `CONFIRM_MAINNET` set to the chain's name, so one typo cannot deploy to the wrong chain.
Verification tries these in order:

1. Etherscan v2 multichain API, when `ETHERSCAN_API_KEY` is set (one key covers every chain; Base, BNB, OP and Avalanche need a paid Etherscan plan);
2. the chain's Blockscout (Arc, Robinhood);
3. Sourcify, which needs no key.

Anything still unverified is written into `deployments/X.json` as a TODO. The standard-JSON input for manual verification goes to `deployments/verify/`.

## ERC-8004 registries

The official ERC-8004 v2.0.0 registries sit at the same addresses wherever they exist. `getVersion()` returns `2.0.0`.

- Identity Registry: `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`
- Reputation Registry: `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`
- Validation Registry: `0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58`

They are present on Ethereum, Base, BNB, Celo, Polygon, Optimism, Arbitrum, Avalanche, Gnosis, Linea, Scroll, Mantle, Arc, Monad and Robinhood Chain.
They are **absent on Unichain and Sonic** (checked 16 Oct 2026). Each fork record has the per-chain result in `erc8004`.

`PredgeAgentValidator` does not reference the registry, and it should not: it is a standalone contract with the Validation Registry's interface, and it takes no registry address.
The integration is off-chain and per call:

- `agentId` should be the agent's token id in that chain's Identity Registry;
- where the official Validation Registry exists, Predge also posts `validationResponse` there, as on Monad.

Wiring the registry address into the contract would mean new source and a new audit.

## Add a new chain in 10 minutes

1. **Config (2 min).** Add an entry to `config/chains.json`:
   ```json
   "newchain": { "chainId": 12345, "rpc": ["https://rpc.newchain.xyz", "https://backup"], "native": "NEW",
                 "coingecko": "<coingecko id>", "explorer": "https://scan.newchain.xyz",
                 "verify": { "kind": "etherscan-v2" } }
   ```
   - For Blockscout use `"verify": { "kind": "blockscout", "api": "https://…/api" }`.
   - For an OP-stack L2 add `"l1fee": "op-stack"`, for Arbitrum Orbit `"l1fee": "arbitrum"`, for Scroll `"l1fee": "scroll"`.
2. **Probe (1 min).** Run `npm run chains newchain`.
   - The chainId must match.
   - `cancun yes` is required. If the chain lacks MCOPY or PUSH0, stop: this bytecode will not run there.
   - The deployer nonce must be 0.
3. **Fork test (2 min).** Run `node deploy.mjs --chain newchain --fork`.
   - Expect 6 deploys, 23 checks and 13 e2e txs.
   - The 6 addresses must equal the table above.
4. **Price it (1 min).** Run `npm run funding`, then send the "Send" amount of the native token to the deployer.
5. **Deploy (3 min).** Run `CONFIRM_MAINNET=newchain node deploy.mjs --chain newchain --broadcast`.
6. **Commit (1 min).** Commit `deployments/newchain.json`.

If a client needs a chain without cancun, the set has to be compiled for an older EVM version. That changes the bytecode, so it is a new canonical set with its own deployer and its own addresses. Do not mix it into this one.

## Existing (legacy) deployments

These stay valid. The canonical set is deployed next to them.

- **Arc (5042)**: full set from `0xEc7A…6223`. Bond v2.1 is `0xfeE8…0FDA`, arbiter v2 is `0xA9c3…6E89`. No gaps.
- **Arbitrum One (42161)** and **Robinhood Chain (4663)**: validator, job, bond v2.1 (ARB `0x3db3…f04f`, RH `0xee76…9737`) and settlement from `0x1d48…cF3c`. **Missing: the arbiter v2.**
- **Monad (143)**: validator `0xf4EE…eeF9`, job, bond `0xd7bC…7111` and settlement from `0x9F0A…9Fc9`. **Missing: the arbiter v2.**

Deploying the canonical set on these four fills the arbiter gap. It also gives them the same addresses as every other chain.

## Security notes

- The key never leaves `~/.predge-deployer/deployer.json`.
  - The tool refuses to load the file if group or other users have any permission bits on it.
  - The key is never printed, and the file is outside the repo.
- Fork runs sign with the real key against a local anvil only. The signed transactions are not stored.
- The arbiter's `refundProtocol` is immutable and points at the mock on every chain. When Circle's Refund Protocol exists on a chain, that chain needs a new arbiter instance. Deploy it from a separate deployer so this set's nonce alignment is not disturbed.
- Before mainnet promises, read the audit caveats: F3 (the arbiter refunds before the challenge window closes) and F4 (a demo run from a single key never exercises a slash).
