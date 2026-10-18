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

## Deployments

Live on **14 mainnets** since 18 Oct 2026, all six contracts at the canonical addresses above. Checked the same day with `eth_getCode` on every chain, and every contract is an exact match on [Sourcify](https://sourcify.dev). Full receipts (block, gas, constructor args, source hash) are in `deployments/<chain>.json`.

Creation transactions, in nonce order:

| Chain | chainId | Receipt | Validator | Job | Bond | Settlement | Mock | Arbiter |
|---|---|---|---|---|---|---|---|---|
| Ethereum | 1 | [json](deployments/ethereum.json) | [0xc7bd…78a5](https://etherscan.io/tx/0xc7bd4d62b66d4be7af342014c07de8239f4e112fcd9db71142c750925f5a78a5) | [0xff87…85fc](https://etherscan.io/tx/0xff874aab3d016283c3c83ac3d74fc8d958dc167a6852dfd2e092c9342ee085fc) | [0x2653…ef36](https://etherscan.io/tx/0x26537d5478bd62c8eb87b533bba8b3f048cea6510b99800424a2df5e2a98ef36) | [0x6b62…f377](https://etherscan.io/tx/0x6b623d1889893bc9c1117b44701e78e0d902d80f5c09447740d26632dd92f377) | [0x8fe6…9d1e](https://etherscan.io/tx/0x8fe6db9b6450251a65b7081bd75f42eec59d94de613287ca31102873c0339d1e) | [0x54d3…776b](https://etherscan.io/tx/0x54d32626fe3e3919a35b7525777e5e00b0ea63691d6a46fb417727fa9266776b) |
| Base | 8453 | [json](deployments/base.json) | [0xbe87…c008](https://basescan.org/tx/0xbe87be37c6865db8bcf44d12bd45fb6ce24845ce6dfd1ad9f9605fec0e3ac008)* | [0x4078…254d](https://basescan.org/tx/0x4078aed416ce44c70ef754719705bfed6ed343cf8cf716e0d5c18178c62c254d) | [0x1086…d085](https://basescan.org/tx/0x1086eb67ba2464f0411f222be7ae541b543ee547bacc2963f5c71297472cd085) | [0x7415…978b](https://basescan.org/tx/0x7415e3fea5cac3e5702b326dc5a32f9372c3e417dc48dd574224a6e7ae65978b) | [0xe307…e08d](https://basescan.org/tx/0xe30730facaa7a9d796de25c26f51517fb4cf3bdc79e205e7353baf5daffce08d) | [0xa2f7…96f4](https://basescan.org/tx/0xa2f79a28a01b1a9c9574b1ab25233684c0fe8dab2b780d9a5d6de190241196f4) |
| BNB Chain | 56 | [json](deployments/bnb.json) | [0x15c2…83d5](https://bscscan.com/tx/0x15c2715ca83b6334d3d17283e1c321234456f860cb3aef4ceda63479ab7d83d5) | [0x0ec1…bfda](https://bscscan.com/tx/0x0ec123b990b0ac78148132e94238d6114ae01cff2f7a334dbc3f1b506062bfda) | [0x341f…8afd](https://bscscan.com/tx/0x341f3b28814ca3f07569a13db1b07175529bdf436e06c851c3a980153bbe8afd) | [0x1aef…b908](https://bscscan.com/tx/0x1aef105effc6807aed3a3405ceea6934dfb3cde147e32419ac8e3e806cd6b908) | [0xb434…936a](https://bscscan.com/tx/0xb434094580188437dcbd8d43ea393621d0e18b7aa258cc1cba8839711f4e936a) | [0x3312…32cb](https://bscscan.com/tx/0x3312f122d341ad06c6f40c32390eccf794d085b27c804d7ff0ef94e8419e32cb) |
| Arbitrum One | 42161 | [json](deployments/arbitrum.json) | [0x6bf0…deb5](https://arbiscan.io/tx/0x6bf091c7193754fb36d8ef504059ddc72bb97b4e44fe51333d5289eaf5c7deb5) | [0xeb37…828f](https://arbiscan.io/tx/0xeb3719a002da8678ef37c75d7ede0bcd52003a64f62f975721f1baf53a81828f) | [0x6258…c100](https://arbiscan.io/tx/0x625862da612fe4ee15aa319616263cfc6e9baa1b9cc7995a9aca12fda30ec100) | [0x9f0e…7356](https://arbiscan.io/tx/0x9f0eeb2b311202a52044edf1ce3b69ed1d1f5c5cf06fdddf9027734a0e507356) | [0x2ad8…cfb6](https://arbiscan.io/tx/0x2ad89a956dc32f5e2e30250b037de4898ffe65754a86c373c0c0d989ad24cfb6) | [0xa4ab…07a8](https://arbiscan.io/tx/0xa4abda2ca31036b66105f39b602711e74f9f6bacbd66205e7dcf7db4b84607a8) |
| Optimism | 10 | [json](deployments/optimism.json) | [0x6b6d…e650](https://optimistic.etherscan.io/tx/0x6b6d549dad61549af48af5c1ce219fd11f07654bcc97ece07290fc59714be650)* | [0x3067…fe50](https://optimistic.etherscan.io/tx/0x3067b27b1914f1aadd24f73c952c23f0a5a71cbac85b833953c3bb412b20fe50) | [0x2c2f…796e](https://optimistic.etherscan.io/tx/0x2c2f55db37cc367940e6196de2e4f792db8f5eeb7b4af8e00d18a696feb8796e) | [0x0c9f…ff74](https://optimistic.etherscan.io/tx/0x0c9fec24d004fc91e6a489c1317108fcf637e4c7628d593f75003c6d5e49ff74) | [0x7e2e…4295](https://optimistic.etherscan.io/tx/0x7e2e370ab157469b98f0dbeb2ff447bb142da20c0e164536e5d244cc5ff44295) | [0x708b…2bb9](https://optimistic.etherscan.io/tx/0x708b47106539b7833d6d1b7bf5c9be460580ec84e029ceb7d98274dba6412bb9) |
| Polygon | 137 | [json](deployments/polygon.json) | [0x180f…f514](https://polygonscan.com/tx/0x180febf90d433aa1dbff37d166d4450974612dcdaf96df7fbb9afe072e62f514) | [0x0f3e…ec71](https://polygonscan.com/tx/0x0f3e60305d8d782e2932c4f691fce4e509d6947695de3a52fdc42920cbd0ec71) | [0x175d…fe43](https://polygonscan.com/tx/0x175d934b198bf8bc0ae1b3b19530f43a4771bd54e235e0373bb6fd3f2767fe43) | [0xb853…fb78](https://polygonscan.com/tx/0xb85328e364ee182d294f9a6179b3ca0aa5e492082198286da41e077da822fb78) | [0x7c5d…53b1](https://polygonscan.com/tx/0x7c5d1f98a452ee43bb29a4ab512ee0a3ec5ea5a8ca5fc4a4525b33fb5be953b1) | [0xdb7e…2506](https://polygonscan.com/tx/0xdb7e5597a1fabaf1ad1aad05377a52e9bf0cb2be6a7d6cc0e9e006e318032506) |
| Avalanche C-Chain | 43114 | [json](deployments/avalanche.json) | [0x15d5…de69](https://snowtrace.io/tx/0x15d56dfebbb34eb7fc0cf7f8e68c3f1a226adb4c8726b5b51380fcafc922de69) | [0x60d8…4082](https://snowtrace.io/tx/0x60d8cd69e3652a185fb4cb838268942acab9f50bc7da6240e39b218f6dcd4082) | [0x2e5b…a17d](https://snowtrace.io/tx/0x2e5bd2c5a21fc30a3463db8fa6ad83b9559a137f57232baa56080f388c2aa17d) | [0x4f5a…f179](https://snowtrace.io/tx/0x4f5aca5244c26b9056f6778fb6481931b341a29b23023bd29a3db61b342cf179) | [0x41d3…0872](https://snowtrace.io/tx/0x41d3a4d9d742018cbcc33487788d33c26a8867aa420448cef0d1aa5c4c0e0872) | [0x9dd2…e5cc](https://snowtrace.io/tx/0x9dd24dc9bde1a4b4c84399c9d69030a667afb9b039c0ea34e9bb42ee4a2be5cc) |
| Celo | 42220 | [json](deployments/celo.json) | [0x9fe1…c8f0](https://celoscan.io/tx/0x9fe1e5f0a6c7ef81fe641a419c8141ff2d38496e0b4dde60d1b831a4fdf6c8f0) | [0x30a7…6437](https://celoscan.io/tx/0x30a74b77957e251fb9e31e7f4134e4696268025d3676de3d18d96b56210f6437) | [0x7bcd…081c](https://celoscan.io/tx/0x7bcd82c6f67e0f87025cc9f752eb852b309e9f92f335c31782b10515e86f081c) | [0xa1bb…5d7e](https://celoscan.io/tx/0xa1bbba782a67fb1582a3fbf13227e49a9cb2e5e263dbdde0e94f8e2a2b425d7e) | [0x1a2f…5b06](https://celoscan.io/tx/0x1a2f6f1c1d57ef276c106143f515c3cb78f75186f946d2f81e390de1af7d5b06) | [0x3bde…363f](https://celoscan.io/tx/0x3bde88d1df4d15daa3601190057421bae60721b9ce41c308259d9ccc5537363f) |
| Gnosis | 100 | [json](deployments/gnosis.json) | [0x4895…208a](https://gnosisscan.io/tx/0x489550048ec9efb00c29b78fb389e42e1b38b6168c406807eae6020238a7208a) | [0x19ab…7f06](https://gnosisscan.io/tx/0x19ab0608be78907337c13eb9b652eaf87cb701d5ba87054ec6d338d2e7ba7f06) | [0xd02a…5c9e](https://gnosisscan.io/tx/0xd02a6feff7633c8d8bcbc00eb8e697884213faf4d8c913cb7a256f2ea7665c9e) | [0x7291…0dca](https://gnosisscan.io/tx/0x7291a8dfb1d5dc426e08ce04b3b5c980ce1ecc422550602aea26c57bfd880dca) | [0xee0f…69b2](https://gnosisscan.io/tx/0xee0f689a0f70750e355f0eb08f79ddcedfe706a3082f30173d822181e63769b2) | [0x61d2…4240](https://gnosisscan.io/tx/0x61d262d54b4657150101bb53d37add5b0b285aa27463e641408ef00dae124240) |
| Linea | 59144 | [json](deployments/linea.json) | [0xb742…98e1](https://lineascan.build/tx/0xb7425896f0e9e0ac88d9ae4560f2af62beb7727c9efe67e6d707532656c998e1) | [0x3f4c…e98d](https://lineascan.build/tx/0x3f4cee396fe422249edcc05c8ea3eeb20d215938cd0e3bdfa9a2907eafeae98d) | [0xf779…3e78](https://lineascan.build/tx/0xf77976a0bd85a3dc46ad3dc2b54410f1fb3d985180b6005ee3d8b1bd7c893e78) | [0xe162…592b](https://lineascan.build/tx/0xe162edd793541c344d07b9c923a0a19a9bc754457c9c6241c2b36d822623592b) | [0xb8f0…1c3e](https://lineascan.build/tx/0xb8f0f69aaa65a817c4ef231d499593dcb860bd8766b9d4101bd2e217880c1c3e) | [0x3f74…1e41](https://lineascan.build/tx/0x3f7459aa306ed8910d5383fab083600f26e784583df8aa8d0b7f60dd22601e41) |
| Unichain | 130 | [json](deployments/unichain.json) | [0x2acb…4914](https://uniscan.xyz/tx/0x2acb8262a6571563314a3b2b07f455b20680b5f8bb24c160fb60a28e033b4914)* | [0xeeba…9f2d](https://uniscan.xyz/tx/0xeeba71889b530e56ab155db959fca055515749e08cacdb15d0e6b2ed3a529f2d)* | [0xee31…2a58](https://uniscan.xyz/tx/0xee318bdb2c995b8af6f26ecda4c3a1006f82bb219a5bb651bf6b09bd82292a58)* | [0xa06c…3526](https://uniscan.xyz/tx/0xa06c834e22171a60a41a65932959a0a588951d6b6a0ff2d410770b4b7ee33526)* | [0xd492…e7d9](https://uniscan.xyz/tx/0xd492bcd1ab49a8867372e407d0f143dc7cd720b6bb2a1e98fea3bf8a2445e7d9)* | [0x7cc4…38df](https://uniscan.xyz/tx/0x7cc48d9be5c9a47d937e0a9af1646f0e32a2c02d60ce384c8e880e5b265038df)* |
| Sonic | 146 | [json](deployments/sonic.json) | [0xc5f7…b755](https://sonicscan.org/tx/0xc5f7e3ba2667466115e9a8f398e83b1e91fa633caef6e6798c28b85ee6f2b755) | [0x783b…a6c2](https://sonicscan.org/tx/0x783b7141d06b686d461086b7c8750ffea3160bfbe1bb3595658198c22f74a6c2) | [0xfda9…0605](https://sonicscan.org/tx/0xfda9981ce6c365a1b3728f1260099de488f09d606b7ce01c65da7d868e7d0605) | [0xa800…c873](https://sonicscan.org/tx/0xa8007f314704f2ac5cc058c3aaf95f08951b44c41018ea96ae181f73aa5ac873) | [0x51b4…d0ca](https://sonicscan.org/tx/0x51b489e2ce00d36fe748ae9736a6181630d71ce9baadde5b4a4e2cb6a052d0ca) | [0x83e2…a16d](https://sonicscan.org/tx/0x83e29b6a6802c09ef0215dcd116c8650f1c386617848fd9fe18133186ccea16d) |
| Arc | 5042 | [json](deployments/arc.json) | [0x18cb…e89c](https://explorer.arc.io/tx/0x18cb29e091ce81ac2143e5228d1088788a9f62c6907b766367ed19aa9797e89c) | [0xc50a…269d](https://explorer.arc.io/tx/0xc50a9afbb782324d6225014c831d488411dabe82877dca11c32678992198269d) | [0xfa6f…3d2d](https://explorer.arc.io/tx/0xfa6f83799772eeeaa888a032a87ca3c4a6a23d8db2090ada5c844f21a8593d2d) | [0xb3df…edec](https://explorer.arc.io/tx/0xb3dfa808a9bc1a77bbbbe6dc57ebca2595f520871ee402d195445d25ae53edec) | [0xb062…079e](https://explorer.arc.io/tx/0xb0629023a8011f0e036f18314813544a3529e1350374112f7ea56ff0e60e079e) | [0xd06f…74c8](https://explorer.arc.io/tx/0xd06f37b89a89d9f0022b27bdbcd66ba3e5f2d62b30549c8a2b13e8d7b8ac74c8) |
| Monad | 143 | [json](deployments/monad.json) | [0xa65f…916d](https://monadvision.com/tx/0xa65fddaea6108b0ae740e7d726a2a26c437ec24d3f6f09f3783de9571cc4916d) | [0xb66d…6bd6](https://monadvision.com/tx/0xb66d71c96185ac79487e8fb00190e162286bcf48cf001d1d4a93c6639b856bd6) | [0x8445…76b5](https://monadvision.com/tx/0x8445c0ecc1851cb42f82f07ea57564ca3265c47f5c02096ca50d21c1b30976b5) | [0x4af2…902b](https://monadvision.com/tx/0x4af2caaa7dfae810c6f9c19cd3cd82675fd1f163ad3ead8bc6965ff2e6f0902b) | [0x73f3…d487](https://monadvision.com/tx/0x73f353b59b0e0e17fea89689bc7bde5cf9aabfdce5aa9562989bdc3b3662d487) | [0xdd18…4a30](https://monadvision.com/tx/0xdd1810d0209adb4fea3f3159ce34bc4e9b0f5488dff84a83d7fed59fab594a30) |

\* Deployed by an earlier, interrupted run of the same tool, so the resumed run's receipt marks it as skipped. The hash comes from Sourcify's deployment record and was checked on chain (status 1, from the deployer, contractAddress matches).

**Coming:** Mantle (5000) and Robinhood Chain (4663), waiting for deployer funding. Scroll was dropped.

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
