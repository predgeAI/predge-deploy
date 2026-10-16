# Predge multi-chain deploy: funding needed

Generated 2026-10-16T20:06:26.147Z by `predge-deploy/scripts/funding.mjs`. Nothing has been broadcast to any mainnet.

**Fund this one address on every chain:** `0x5d016C1B4d7A42eB7c982da1Ae7fFdB958CFCAe9` (dedicated Predge deployer, created 16 Oct 2026, key in ~/.predge-deployer/deployer.json, 0600).
Send ONLY the native gas token. Do not send anything else from or to this address before the deploy: the contract addresses depend on its nonce being 0.

Method: gas = exact `gasUsed` of the 6 deploy txs on an `anvil --fork-url` of each mainnet; price = live `eth_gasPrice` now; plus the L2 data fee (OP-stack / Scroll oracle `getL1Fee`, Arbitrum NodeInterface) read from the live chain; +50% buffer (or the per-tx upfront maxFee check if that is higher). USD from CoinGecko at generation time.

| Chain | chainId | Gas used (fork) | Gas price (gwei) | L2 data fee | Cost | **Send (incl. 50%)** | USD | Deployer nonce / balance now |
|---|---|---|---|---|---|---|---|---|
| ethereum | 1 | 4226284 | 0.0843 | 0 ETH | 0.000356 ETH | **0.000534 ETH** | $1.29 | 0 / 0 |
| base | 8453 | 4226284 | 0.006 | 1.09e-7 ETH | 0.0000255 ETH | **0.0000415 ETH** (floor) | $0.100 | 0 / 0 |
| bnb | 56 | 4226284 | 0.05 | 0 BNB | 0.000211 BNB | **0.000317 BNB** | $0.228 | 0 / 0 |
| celo | 42220 | 4226284 | 203 | 0 CELO | 0.856 CELO | **1.28 CELO** | $0.109 | 0 / 0 |
| polygon | 137 | 4226284 | 282 | 0 POL | 1.19 POL | **1.79 POL** | $0.168 | 0 / 0 |
| optimism | 10 | 4226284 | 0.00102 | 1.51e-7 ETH | 0.00000445 ETH | **0.0000415 ETH** (floor) | $0.100 | 0 / 0 |
| arbitrum | 42161 | 4226284 | 0.02 | 4.97e-7 ETH | 0.0000851 ETH | **0.000128 ETH** | $0.307 | 0 / 0 |
| avalanche | 43114 | 4226284 | 5 | 0 AVAX | 0.0211 AVAX | **0.0317 AVAX** | $0.317 | 0 / 0 |
| gnosis | 100 | 4226284 | 9.00e-9 | 0 xDAI | 3.80e-11 xDAI | **0.1 xDAI** (floor) | $0.100 | 0 / 0 |
| linea | 59144 | 4226284 | 0.51 | 0 ETH | 0.00216 ETH | **0.00323 ETH** | $7.79 | 0 / 0 |
| scroll | 534352 | 4226284 | 0.00012 | 0.0000979 ETH | 0.0000984 ETH | **0.000148 ETH** | $0.355 | 0 / 0 |
| unichain | 130 | 4226284 | 0.0015 | 8.16e-8 ETH | 0.00000642 ETH | **0.0000415 ETH** (floor) | $0.100 | 0 / 0 |
| sonic | 146 | 4226284 | 55 | 0 S | 0.232 S | **1.85 S** (floor) | $0.100 | 0 / 0 |
| mantle | 5000 | 4226284 | 50 | 0.00000293 MNT | 0.211 MNT | **0.317 MNT** | $0.170 | 0 / 0 |
| arc | 5042 | 4226284 | 21.5 | 0 USDC | 0.0908 USDC | **0.136 USDC** | $0.136 | 0 / 0 |
| monad | 143 | 4869930 | 102 | 0 MON | 0.497 MON | **4.44 MON** (floor) | $0.100 | 0 / 0 |
| robinhood | 4663 | 4226284 | 0.0207 | 0 ETH | 0.0000877 ETH | **0.000131 ETH** | $0.317 | 0 / 0 |
| **Total** | | | | | | | **$11.78** | |

Token prices used: ethereum $2408.48, binancecoin $720.41, celo $0.084801, polygon-ecosystem-token $0.093798, avalanche-2 $9.99, xdai $0.999698, sonic-3 $0.054116, mantle $0.535764, usd-coin $0.999744, monad $0.02251012.

Notes
- Arc, Monad, Robinhood Chain and Arbitrum One already have the legacy set from other deployers (Arc complete; the other three lack the arbiter v2). The canonical set adds the arbiter there and the same addresses as everywhere else; the legacy addresses stay valid.
- "(floor)": the real cost is below $0.10, so the table asks for $0.10 worth instead.
- Monad bills gasLimit x price, so its "gas" column is the billed limit (gasUsed +15%), not gasUsed.
- Arc gas is paid in native USDC (18 decimals on Arc).
- Per-chain detail (gas per contract, e2e tx gas, ERC-8004 registries): `predge-deploy/deployments/fork/<chain>.json`.
