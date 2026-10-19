// The Foundry suite (test/foundry) must exercise the same runtime code we deploy. forge and
// lib/compile.mjs use different source paths, so only the CBOR metadata tail may differ; the
// executable runtime must be byte-identical. Skipped when `forge build` has not been run.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { compile } from "../lib/compile.mjs";

const OUT = new URL("../out-foundry/", import.meta.url);
const NAMES = ["AgentJob", "MockRefundProtocol", "PredgeAgentValidator", "PredgeRefundArbiter", "PredgeSettlement", "PredgeValidatorBond"];
const stripMetadata = (hex) => {
  const h = hex.replace(/^0x/, "");
  const len = parseInt(h.slice(-4), 16);
  return h.slice(0, h.length - 4 - len * 2);
};

for (const name of NAMES) {
  const artifact = new URL(`${name}.sol/${name}.json`, OUT);
  test(`${name}: forge runtime == deploy runtime (metadata excluded)`, { skip: !existsSync(artifact) && "run forge build first" }, () => {
    const forge = JSON.parse(readFileSync(artifact, "utf8")).deployedBytecode.object;
    assert.equal(stripMetadata(forge), stripMetadata(compile(name).deployedBytecode));
  });
}
