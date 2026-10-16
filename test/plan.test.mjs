// Addresses depend only on the deployer and the nonce order, never on the chain.
import { test } from "node:test";
import assert from "node:assert/strict";
import { getCreateAddress } from "ethers";
import { resolvePlan } from "../lib/plan.mjs";

const D = "0x5d016C1B4d7A42eB7c982da1Ae7fFdB958CFCAe9";

test("canonical addresses for the Predge deployer", () => {
  const p = resolvePlan(D);
  assert.deepEqual(p.map((s) => [s.name, s.address]), [
    ["PredgeAgentValidator", "0x925767fdce6C819F027f55CC50464e3bCdfD2671"],
    ["AgentJob", "0xcBaB4a9FA4d756b4C5e2a18F055d2E0132CE7D1D"],
    ["PredgeValidatorBond", "0x800B5596a8540e752dE8f8a8AF99E927d139A643"],
    ["PredgeSettlement", "0x47BE8a7d461De505723a0Ac1d74982e53f8E412b"],
    ["MockRefundProtocol", "0xcaC30945CDF0F963f38972d939e111B87b80Cf79"],
    ["PredgeRefundArbiter", "0xb2972B4944Eec83946EB7B23D572AbE04F46E22c"],
  ]);
});

test("forward and backward references resolve to the sibling addresses", () => {
  const p = resolvePlan(D);
  const by = Object.fromEntries(p.map((s) => [s.name, s]));
  assert.equal(by.PredgeAgentValidator.args[0], D);
  assert.equal(by.PredgeValidatorBond.args[1], by.AgentJob.address);
  assert.equal(by.MockRefundProtocol.args[0], by.PredgeRefundArbiter.address);
  assert.equal(by.PredgeRefundArbiter.args[0], by.MockRefundProtocol.address);
  p.forEach((s, i) => assert.equal(s.address, getCreateAddress({ from: D, nonce: i })));
});

test("initcode is identical for every chain (no chain-dependent input)", () => {
  assert.deepEqual(resolvePlan(D).map((s) => s.initcode), resolvePlan(D).map((s) => s.initcode));
});
