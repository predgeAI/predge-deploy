// The set we deploy must be the set that is already live and audited: compile here, read the
// runtime code from the existing mainnet deployments, compare with immutables masked.
import { test } from "node:test";
import assert from "node:assert/strict";
import { compile, maskImmutables } from "../lib/compile.mjs";

const LIVE = [
  // chain RPC, contract, address (all from the repos' deployment records)
  ["https://rpc.mainnet.arc.io", "PredgeValidatorBond", "0xfeE8b89eb8aa2499F7025Cd9aaEB13a4b046d0d1"],
  ["https://rpc.mainnet.arc.io", "PredgeRefundArbiter", "0xA9c39e9aEd452Ee638a10aC10f6A6288C4Ca6E89"],
  ["https://rpc.mainnet.arc.io", "MockRefundProtocol", "0xf6659f725B3F790287a75f7A83C373E2a3D908aa"],
  ["https://rpc.mainnet.arc.io", "PredgeAgentValidator", "0xbe601d486D821450F9248ab91891736B1a09699F"],
  ["https://rpc.mainnet.arc.io", "AgentJob", "0x8B9589B8F5857dDe080Ac68e8B370c3bA5E74495"],
  ["https://arb1.arbitrum.io/rpc", "PredgeValidatorBond", "0x3db39A8dFdc7157f8B8a2AacD201081378Cef04f"],
  ["https://arb1.arbitrum.io/rpc", "PredgeSettlement", "0xB9CC5F71830743664a912cA0f70e019280c1893B"],
  ["https://rpc.monad.xyz", "PredgeAgentValidator", "0xf4EE0Af65804D5754E59316b3DBB53D5c3AeeeF9"],
  ["https://rpc.monad.xyz", "PredgeValidatorBond", "0xd7bC19f836a92561b368eFf34667c32cAe4E7111"],
  ["https://rpc.monad.xyz", "AgentJob", "0x64668df7917A84a26d53Fff7883DD998258D6987"],
];

async function getCode(url, address) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }) });
  return (await r.json()).result;
}

for (const [url, name, address] of LIVE) {
  test(`${name} at ${address} (${new URL(url).host}) matches the compiled runtime`, async () => {
    const c = compile(name);
    const onchain = await getCode(url, address);
    assert.ok(onchain && onchain.length > 2, "no code on chain");
    assert.equal(maskImmutables(onchain, c.immutableReferences), maskImmutables(c.deployedBytecode, c.immutableReferences));
  });
}
