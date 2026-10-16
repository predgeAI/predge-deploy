// Read-only health check for every configured chain (or the ones named):
// chainId matches, Cancun opcodes the bytecode needs (PUSH0, MCOPY) execute, gas price,
// ERC-8004 registries present, and the deployer's nonce (must be 0 before the first deploy).
//   node scripts/probe-chains.mjs [chain ...]
import { CHAINS, chainConfig, pickRpc, rawRpc } from "../lib/chains.mjs";
import { deployerAddress } from "../lib/key.mjs";

const REG = { identity: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432", reputation: "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63", validation: "0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58" };
const OPS = { PUSH0: "0x5f5f5500", MCOPY: "0x5f5f5f5e00", INVALID_must_fail: "0xfe" };
const names = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(CHAINS);
const deployer = (() => { try { return deployerAddress(); } catch { return null; } })();

for (const name of names) {
  const c = chainConfig(name);
  try {
    const url = await pickRpc(c);
    const ops = {};
    for (const [k, code] of Object.entries(OPS)) ops[k] = await rawRpc(url, "eth_call", [{ data: code }, "latest"]).then(() => "ok", () => "fails");
    const cancun = ops.PUSH0 === "ok" && ops.MCOPY === "ok" && ops.INVALID_must_fail === "fails";
    const gwei = Number(BigInt(await rawRpc(url, "eth_gasPrice"))) / 1e9;
    const regs = [];
    for (const [k, a] of Object.entries(REG)) if ((await rawRpc(url, "eth_getCode", [a, "latest"])).length > 2) regs.push(k);
    const nonce = deployer ? parseInt(await rawRpc(url, "eth_getTransactionCount", [deployer, "latest"]), 16) : "?";
    console.log(`${name.padEnd(10)} id ${String(c.chainId).padEnd(7)} cancun ${cancun ? "yes" : "NO " + JSON.stringify(ops)}  gas ${gwei.toPrecision(3)} gwei  erc8004 [${regs.join(",") || "none"}]  deployer nonce ${nonce}  ${url}`);
  } catch (e) {
    console.log(`${name.padEnd(10)} ERROR ${e.message}`);
  }
}
