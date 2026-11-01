// Resolves the canonical plan for one deployer: every address is known before anything is sent,
// because contract i is created by the deployer's nonce `nonceBase + i` (CREATE), on every chain. `nonceBase` comes from
// the set file (0 if absent): a later version of a set can reuse the same deployer key after the earlier version.
import { getCreateAddress, ContractFactory } from "ethers";
import { SET as SET_V1 } from "./chains.mjs";
import { compile } from "./compile.mjs";

export function resolvePlan(deployer, overrides = {}, SET = SET_V1) {
  const params = { ...SET.params, ...overrides };
  const base = SET.nonceBase ?? 0;
  const addresses = Object.fromEntries(SET.plan.map((s, i) => [s.name, getCreateAddress({ from: deployer, nonce: base + i })]));
  const ctx = { deployer, ...params, ...addresses };
  if (params.operator === "$deployer") ctx.operator = deployer;
  const resolve = (a) => {
    if (typeof a !== "string" || !a.startsWith("$")) return a;
    const v = ctx[a.slice(1)];
    if (v === undefined) throw new Error(`unresolved plan arg ${a}`);
    return v;
  };
  return SET.plan.map((step, i) => {
    const nonce = base + i;
    const c = compile(step.name, step.file);
    const args = step.args.map(resolve);
    const data = new ContractFactory(c.abi, c.bytecode).interface.encodeDeploy(args);
    return { ...step, nonce, address: addresses[step.name], args, constructorArgs: data, initcode: c.bytecode + data.slice(2), compiled: c };
  });
}
