// v2 plan: deterministic addresses, role wiring, config safety, pinned compiler. No network.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { getCreateAddress, Wallet } from "ethers";
import { resolvePlan } from "../lib/plan.mjs";
import { SET_V2, CHAINS } from "../lib/chains.mjs";
import { chainParams, realRoles, v2KeyFile, ANVIL_KEYS, forkRoles } from "../lib/v2.mjs";

const D = "0x1111111111111111111111111111111111111111"; // sample only
const OWNER = "0x2222222222222222222222222222222222222222";
const OP = "0x3333333333333333333333333333333333333333";
const plan = (chain = "base", d = D) => resolvePlan(d, { owner: OWNER, operator: OP, ...chainParams(chain) }, SET_V2);

test("addresses depend only on deployer and nonce order, not on the chain or chain params", () => {
  const a = plan("base"), b = plan("arc");
  assert.deepEqual(a.map((s) => s.address), b.map((s) => s.address));
  a.forEach((s, i) => assert.equal(s.address, getCreateAddress({ from: D, nonce: (SET_V2.nonceBase ?? 0) + i })));
  a.forEach((s, i) => assert.equal(s.nonce, (SET_V2.nonceBase ?? 0) + i));
  assert.notDeepEqual(a.map((s) => s.initcode), b.map((s) => s.initcode), "bond floors differ per chain, so initcode does");
});

test("v2.1 continues the 20.10 deployer at nonce 6 (nonces 0..5 hold the v2.0 set on Arc and Base)", () => {
  assert.equal(SET_V2.nonceBase, 6);
  const live = JSON.parse(readFileSync(new URL("../deployments/v2/arc.json", import.meta.url), "utf8"));
  const p = resolvePlan(live.deployer, { owner: OWNER, operator: OP, ...chainParams("arc") }, SET_V2);
  const old = new Set(Object.values(live.contracts).map((c) => c.address));
  for (const s of p) assert.ok(!old.has(s.address), `${s.name} would collide with a v2.0 address`);
});

test("the plan order is fixed: append-only", () => {
  assert.deepEqual(SET_V2.plan.map((s) => s.name), ["PredgeAgentValidatorV2", "AgentJobV2", "PredgeValidatorBondV2", "PredgeSettlementV2", "MockRefundProtocolV2", "PredgeRefundArbiterV2"]);
});

test("roles are wired from the constructor args and the deployer holds none", () => {
  const by = Object.fromEntries(plan().map((s) => [s.name, s]));
  assert.equal(by.PredgeAgentValidatorV2.args[0], OWNER);
  assert.equal(by.PredgeAgentValidatorV2.args[1], OP);
  assert.equal(by.PredgeValidatorBondV2.args[0], OWNER);
  assert.equal(by.PredgeValidatorBondV2.args[1], OP);
  assert.equal(by.PredgeValidatorBondV2.args[2], by.AgentJobV2.address);
  assert.equal(by.PredgeSettlementV2.args[0], OWNER);
  assert.equal(by.MockRefundProtocolV2.args[0], by.PredgeRefundArbiterV2.address);
  assert.equal(by.PredgeRefundArbiterV2.args[2], by.MockRefundProtocolV2.address);
  for (const s of Object.values(by)) assert.ok(!s.args.includes(D), `${s.name} must not take the deployer as an argument`);
});

test("every chain has a non-zero bond floor, and the live config refuses to run while unset (or is complete)", () => {
  for (const name of Object.keys(CHAINS)) {
    const p = chainParams(name);
    assert.ok(BigInt(p.minBond) > 0n && BigInt(p.arbiterMinBond) > 0n, name);
  }
  // Since 20.10 the owner has filled config/v2.config.json; before that realRoles() had to refuse to run.
  let roles = null;
  try { roles = realRoles(); } catch (e) { assert.match(e.message, /is not set/); }
  if (roles) assert.equal(new Set(Object.values(roles)).size, 3, "deployer, owner and operator are distinct");
});

test("v2 key handling: never the v1 key dir; fork accounts are not accepted as real roles", () => {
  assert.throws(() => v2KeyFile(undefined), /--key-file/);
  assert.throws(() => v2KeyFile("/Users/x/.predge-deployer/deployer.json"), /refusing/);
  assert.equal(v2KeyFile("/tmp/new-v2.json"), "/tmp/new-v2.json");
  const f = forkRoles();
  assert.equal(new Set(Object.values(f)).size, 3);
  assert.equal(new Wallet(ANVIL_KEYS[1]).address, f.owner);
});

test("every v2 source pins solc 0.8.26 exactly and has no floating pragma", () => {
  const walk = (dir) => readdirSync(dir).flatMap((n) => { const p = `${dir}/${n}`; return statSync(p).isDirectory() ? walk(p) : p.endsWith(".sol") ? [p] : []; });
  const files = walk(new URL("../contracts/v2", import.meta.url).pathname);
  assert.ok(files.length >= 8);
  for (const f of files) assert.match(readFileSync(f, "utf8"), /^pragma solidity 0\.8\.26;$/m, f);
});

test("v2 contracts carry no selfdestruct, delegatecall, tx.origin or inline assembly", () => {
  const files = SET_V2.plan.map((s) => readFileSync(new URL(`../contracts/${s.file}.sol`, import.meta.url), "utf8"));
  for (const src of files) assert.doesNotMatch(src.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, ""), /selfdestruct|delegatecall|tx\.origin|assembly/);
});
