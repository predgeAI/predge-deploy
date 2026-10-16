// One compiler, one set of settings, for every chain. The settings are the ones the audited
// Arc / Arbitrum / Robinhood / Monad deployments were built with, so the creation code we ship is
// byte-identical to what is already verified there (see `npm test`, which checks it against Arc).
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import solc from "solc";

export const SOLC_VERSION = "0.8.26";
export const SETTINGS = {
  optimizer: { enabled: true, runs: 200 },
  evmVersion: "cancun",
  outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "evm.deployedBytecode.immutableReferences", "metadata"] } },
};

const CONTRACTS_DIR = new URL("../contracts/", import.meta.url);
const cache = new Map();

/** Standard-JSON input for one contract, exactly as compiled (also what explorers verify against). */
export function standardInput(name) {
  const content = readFileSync(new URL(`${name}.sol`, CONTRACTS_DIR), "utf8");
  return { language: "Solidity", sources: { [`${name}.sol`]: { content } }, settings: SETTINGS };
}

export function compile(name) {
  if (cache.has(name)) return cache.get(name);
  if (!solc.version().startsWith(SOLC_VERSION)) throw new Error(`solc ${solc.version()} != ${SOLC_VERSION}`);
  const input = standardInput(name);
  const out = JSON.parse(solc.compile(JSON.stringify(input)));
  const fatal = (out.errors || []).filter((e) => e.severity === "error");
  if (fatal.length) throw new Error(fatal.map((e) => e.formattedMessage).join("\n"));
  const c = out.contracts[`${name}.sol`][name];
  const res = {
    name,
    abi: c.abi,
    bytecode: "0x" + c.evm.bytecode.object,
    deployedBytecode: "0x" + c.evm.deployedBytecode.object,
    immutableReferences: c.evm.deployedBytecode.immutableReferences || {},
    metadata: c.metadata,
    sourceSha256: createHash("sha256").update(input.sources[`${name}.sol`].content).digest("hex"),
    compilerVersion: "v" + solc.version().replace(".Emscripten.clang", ""),
    input,
  };
  cache.set(name, res);
  return res;
}

/** Runtime code with immutable slots zeroed, so on-chain code can be compared to the compiler's. */
export function maskImmutables(hex, refs) {
  const b = Buffer.from(hex.replace(/^0x/, ""), "hex");
  for (const list of Object.values(refs)) for (const { start, length } of list) b.fill(0, start, start + length);
  return "0x" + b.toString("hex");
}
