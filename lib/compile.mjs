// One compiler, one set of settings, for every chain. The settings are the ones the audited
// Arc / Arbitrum / Robinhood / Monad deployments were built with, so the creation code we ship is
// byte-identical to what is already verified there (see `npm test`, which checks it against Arc).
import { readFileSync } from "node:fs";
import { posix } from "node:path";
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

/** Pulls in every file `entry` imports (relative imports only), so explorers can verify the multi-file v2 contracts. */
function collectSources(entry, out = {}) {
  if (out[entry]) return out;
  const content = readFileSync(new URL(entry, CONTRACTS_DIR), "utf8");
  out[entry] = { content };
  for (const m of content.matchAll(/^\s*import\s+(?:\{[^}]*\}\s+from\s+)?"([^"]+)";/gm)) {
    if (!m[1].startsWith(".")) throw new Error(`${entry}: only relative imports are supported (${m[1]})`);
    collectSources(posix.normalize(posix.join(posix.dirname(entry), m[1])), out);
  }
  return out;
}

/** Standard-JSON input for one contract, exactly as compiled (also what explorers verify against).
 *  v1: one file `<name>.sol`. v2: pass `file` (e.g. "v2/AgentJobV2") and every imported file is included. */
export function standardInput(name, file) {
  if (file) return { language: "Solidity", sources: collectSources(`${file}.sol`), settings: SETTINGS };
  const content = readFileSync(new URL(`${name}.sol`, CONTRACTS_DIR), "utf8");
  return { language: "Solidity", sources: { [`${name}.sol`]: { content } }, settings: SETTINGS };
}

export function compile(name, file) {
  const ck = file ? `${file}:${name}` : name;
  if (cache.has(ck)) return cache.get(ck);
  if (!solc.version().startsWith(SOLC_VERSION)) throw new Error(`solc ${solc.version()} != ${SOLC_VERSION}`);
  const input = standardInput(name, file);
  const key = file ? `${file}.sol` : `${name}.sol`;
  const out = JSON.parse(solc.compile(JSON.stringify(input)));
  const fatal = (out.errors || []).filter((e) => e.severity === "error");
  if (fatal.length) throw new Error(fatal.map((e) => e.formattedMessage).join("\n"));
  const c = out.contracts[key][name];
  const res = {
    name,
    id: `${key}:${name}`,
    abi: c.abi,
    bytecode: "0x" + c.evm.bytecode.object,
    deployedBytecode: "0x" + c.evm.deployedBytecode.object,
    immutableReferences: c.evm.deployedBytecode.immutableReferences || {},
    metadata: c.metadata,
    sourceSha256: createHash("sha256").update(input.sources[key].content).digest("hex"),
    compilerVersion: "v" + solc.version().replace(".Emscripten.clang", ""),
    input,
  };
  cache.set(ck, res);
  return res;
}

/** Runtime code with immutable slots zeroed, so on-chain code can be compared to the compiler's. */
export function maskImmutables(hex, refs) {
  const b = Buffer.from(hex.replace(/^0x/, ""), "hex");
  for (const list of Object.values(refs)) for (const { start, length } of list) b.fill(0, start, start + length);
  return "0x" + b.toString("hex");
}
