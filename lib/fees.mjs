// L2 data fees a local fork cannot show. Asked of the REAL chain with eth_call (read-only).
import { Interface } from "ethers";
import { rawRpc } from "./chains.mjs";

const OP_ORACLE = "0x420000000000000000000000000000000000000F";
const SCROLL_ORACLE = "0x5300000000000000000000000000000000000002";
const ARB_NODE_INTERFACE = "0x00000000000000000000000000000000000000C8";
const iface = new Interface([
  "function getL1Fee(bytes) view returns (uint256)",
  "function gasEstimateL1Component(address to, bool contractCreation, bytes data) payable returns (uint64 gasEstimateForL1, uint256 baseFee, uint256 l1BaseFeeEstimate)",
]);

/** Extra wei on top of gasUsed * gasPrice for one deploy tx. `rawTx` is the signed tx (fork-signed is fine). */
export async function l1FeeWei(chain, url, { rawTx, initcode, gasPrice }) {
  try {
    if (chain.l1fee === "op-stack" || chain.l1fee === "scroll") {
      const to = chain.l1fee === "op-stack" ? OP_ORACLE : SCROLL_ORACLE;
      const res = await rawRpc(url, "eth_call", [{ to, data: iface.encodeFunctionData("getL1Fee", [rawTx]) }, "latest"]);
      return { wei: BigInt(res), how: `${chain.l1fee} oracle getL1Fee` };
    }
    if (chain.l1fee === "arbitrum") {
      const res = await rawRpc(url, "eth_call", [{ to: ARB_NODE_INTERFACE, data: iface.encodeFunctionData("gasEstimateL1Component", ["0x0000000000000000000000000000000000000000", true, initcode]) }, "latest"]);
      const [l1Gas] = iface.decodeFunctionResult("gasEstimateL1Component", res);
      return { wei: BigInt(l1Gas) * gasPrice, how: `arbitrum NodeInterface: ${l1Gas} L1 gas units` };
    }
  } catch (e) {
    return { wei: 0n, how: `unavailable (${String(e.message).slice(0, 80)})` };
  }
  return { wei: 0n, how: "none (execution gas only)" };
}
