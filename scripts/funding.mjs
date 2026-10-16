// Funding table from the fork runs: exact gasUsed per chain (anvil fork) x CURRENT live gas price
// + L2 data fee (asked of the live chain), +50% buffer, priced in USD (CoinGecko). Read-only.
//   node scripts/funding.mjs [--out <file.md>]
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { formatEther, formatUnits } from "ethers";
import { CHAINS, pickRpc, providerFor, chainConfig } from "../lib/chains.mjs";
import { deployerAddress } from "../lib/key.mjs";

const ROOT = new URL("../", import.meta.url).pathname;
const outArg = process.argv.indexOf("--out");
const OUT = outArg > 0 ? process.argv[outArg + 1] : `${ROOT}FUNDING.md`;
const deployer = deployerAddress();

const ids = [...new Set(Object.values(CHAINS).map((c) => c.coingecko))].join(",");
const prices = await (await fetch(`https://api.coingecko.com/api/v3/simple/price?ids=${ids}&vs_currencies=usd`)).json();

const rows = [];
for (const name of Object.keys(CHAINS)) {
  const chain = chainConfig(name);
  const f = `${ROOT}deployments/fork/${name}.json`;
  if (!existsSync(f)) { rows.push({ name, chain, missing: true }); continue; }
  const rec = JSON.parse(readFileSync(f, "utf8"));
  const url = await pickRpc(chain).catch(() => null);
  let gasPrice = BigInt(rec.totals.liveGasPriceWei), maxFee = gasPrice, nonce = null, balance = null;
  if (url) {
    const p = providerFor(url, chain.chainId);
    const fd = await p.getFeeData();
    gasPrice = fd.gasPrice ?? gasPrice;
    maxFee = fd.maxFeePerGas ?? gasPrice;
    [nonce, balance] = await Promise.all([p.getTransactionCount(deployer), p.getBalance(deployer)]);
  }
  const contracts = Object.values(rec.contracts).filter((c) => !c.skipped);
  const pct = BigInt(chain.gasLimitPct ?? 125);
  // Monad bills the gas LIMIT, not gasUsed.
  const billed = (c) => (chain.feeOnGasLimit ? (BigInt(c.gasUsed) * pct) / 100n : BigInt(c.gasUsed));
  const gasUsed = contracts.reduce((a, c) => a + billed(c), 0n);
  const l1 = contracts.reduce((a, c) => a + BigInt(c.l1FeeWei || 0), 0n);
  const cost = gasUsed * gasPrice + l1;
  // The node checks gasLimit * maxFeePerGas per tx up front, so the balance must also cover
  // "spent so far + the next tx at its worst case" at every step.
  let spent = 0n, upfront = 0n;
  for (const c of contracts) {
    const need = spent + (BigInt(c.gasUsed) * pct / 100n) * maxFee + BigInt(c.l1FeeWei || 0);
    if (need > upfront) upfront = need;
    spent += billed(c) * gasPrice + BigInt(c.l1FeeWei || 0);
  }
  const buffered = cost * 150n / 100n;
  const usd = prices[chain.coingecko]?.usd ?? null;
  // Dust floor: on near-free chains still send $0.10 worth, so a gas spike cannot strand a half-deployed set.
  const floor = usd ? BigInt(Math.ceil((0.10 / usd) * 1e18)) : 0n;
  let fund = buffered > upfront ? buffered : upfront;
  const floored = fund < floor;
  if (floored) fund = floor;
  rows.push({ name, chain, rec, gasUsed, gasPrice, l1, cost, fund, floored, usd, nonce, balance, l1how: rec.totals.l1FeeMethod });
}

const n = (wei) => Number(formatEther(wei));
const sig = (x) => (x === 0 ? "0" : x < 1e-6 ? x.toExponential(2) : Number(x.toPrecision(3)).toString());
let total = 0;
const lines = [];
lines.push(`# Predge multi-chain deploy: funding needed`);
lines.push(``);
lines.push(`Generated ${new Date().toISOString()} by \`predge-deploy/scripts/funding.mjs\`. Nothing has been broadcast to any mainnet.`);
lines.push(``);
lines.push(`**Fund this one address on every chain:** \`${deployer}\` (dedicated Predge deployer, created 16 Oct 2026, key in ~/.predge-deployer/deployer.json, 0600).`);
lines.push(`Send ONLY the native gas token. Do not send anything else from or to this address before the deploy: the contract addresses depend on its nonce being 0.`);
lines.push(``);
lines.push(`Method: gas = exact \`gasUsed\` of the 6 deploy txs on an \`anvil --fork-url\` of each mainnet; price = live \`eth_gasPrice\` now; plus the L2 data fee (OP-stack / Scroll oracle \`getL1Fee\`, Arbitrum NodeInterface) read from the live chain; +50% buffer (or the per-tx upfront maxFee check if that is higher). USD from CoinGecko at generation time.`);
lines.push(``);
lines.push(`| Chain | chainId | Gas used (fork) | Gas price (gwei) | L2 data fee | Cost | **Send (incl. 50%)** | USD | Deployer nonce / balance now |`);
lines.push(`|---|---|---|---|---|---|---|---|---|`);
for (const r of rows) {
  if (r.missing) { lines.push(`| ${r.name} | ${r.chain.chainId} | fork run missing | | | | | | |`); continue; }
  const usd = r.usd != null ? n(r.fund) * r.usd : null;
  total += usd ?? 0;
  lines.push(`| ${r.name} | ${r.chain.chainId} | ${r.gasUsed} | ${sig(Number(formatUnits(r.gasPrice, "gwei")))} | ${sig(n(r.l1))} ${r.chain.native} | ${sig(n(r.cost))} ${r.chain.native} | **${sig(n(r.fund))} ${r.chain.native}**${r.floored ? " (floor)" : ""} | $${usd != null ? usd.toFixed(usd < 1 ? 3 : 2) : "?"} | ${r.nonce ?? "?"} / ${r.balance != null ? sig(n(r.balance)) : "?"} |`);
}
lines.push(`| **Total** | | | | | | | **$${total.toFixed(2)}** | |`);
lines.push(``);
lines.push(`Token prices used: ${Object.entries(prices).map(([k, v]) => `${k} $${v.usd}`).join(", ")}.`);
lines.push(``);
lines.push(`Notes`);
lines.push(`- Arc, Monad, Robinhood Chain and Arbitrum One already have the legacy set from other deployers (Arc complete; the other three lack the arbiter v2). The canonical set adds the arbiter there and the same addresses as everywhere else; the legacy addresses stay valid.`);
lines.push(`- "(floor)": the real cost is below $0.10, so the table asks for $0.10 worth instead.`);
lines.push(`- Monad bills gasLimit x price, so its "gas" column is the billed limit (gasUsed +15%), not gasUsed.`);
lines.push(`- Arc gas is paid in native USDC (18 decimals on Arc).`);
lines.push(`- Per-chain detail (gas per contract, e2e tx gas, ERC-8004 registries): \`predge-deploy/deployments/fork/<chain>.json\`.`);
writeFileSync(OUT, lines.join("\n") + "\n");
console.log(lines.join("\n"));
