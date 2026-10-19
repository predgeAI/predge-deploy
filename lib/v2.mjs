// v2 deployment inputs: who the roles are, and the per-chain bond floors.
//   real runs (dry-run / --broadcast): roles come from config/v2.config.json and MUST be set by the owner.
//   --fork: throwaway anvil accounts (the public anvil test keys), never touching ~/.predge-deployer or any real key.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { getAddress, keccak256, toUtf8Bytes, Wallet } from "ethers";

const read = (f) => JSON.parse(readFileSync(new URL(`../config/${f}`, import.meta.url), "utf8"));

/** Fork-only deployer: derived from a public label, so it is NOT secret and must never hold value anywhere real. The anvil
 *  default account 0 cannot be used: on mainnets its nonces 0..5 are already taken by other people's contracts (a fork
 *  deploy at those addresses collides, seen on Arc). */
export const FORK_DEPLOYER_KEY = keccak256(toUtf8Bytes("predge/v2/fork-deployer"));

/** The well-known anvil test mnemonic accounts 1..5 as role actors, PUBLIC keys: fork use only, never for a real chain. */
export const ANVIL_KEYS = [
  FORK_DEPLOYER_KEY, // 0 deployer (fork-only, see above)
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // 1 owner (stands in for the Safe)
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // 2 operator
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // 3 client
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a", // 4 provider
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba", // 5 payer / party
];
export const anvilWallets = (provider) => ANVIL_KEYS.map((k) => new Wallet(k, provider));
const ANVIL_ADDRS = new Set(ANVIL_KEYS.map((k) => new Wallet(k).address));

const PLACEHOLDER_HELP = "edit config/v2.config.json (deployer = new key created for v2, owner = the Safe, operator = the ops key)";

/** Roles for a real run. Throws until the owner has filled them in, and refuses reuse of the v1 deployer. */
export function realRoles() {
  const c = read("v2.config.json");
  const out = {};
  for (const k of ["deployer", "owner", "operator"]) {
    if (!c[k]) throw new Error(`v2 config: "${k}" is not set. ${PLACEHOLDER_HELP}`);
    out[k] = getAddress(c[k]);
    if (ANVIL_ADDRS.has(out[k])) throw new Error(`v2 config: ${k} is a public anvil test address. Use a real one.`);
  }
  if (new Set(Object.values(out)).size !== 3) throw new Error("v2 config: deployer, owner and operator must be three different addresses");
  const v1 = (() => { try { return JSON.parse(readFileSync(`${homedir()}/.predge-deployer/deployer.json`, "utf8")).address; } catch { return null; } })();
  if (v1 && Object.values(out).includes(getAddress(v1))) throw new Error("v2 config: the v1 deployer address must not hold any v2 role or deploy v2");
  return out;
}

export function forkRoles() {
  const [d, o, p] = ANVIL_KEYS.map((k) => new Wallet(k).address);
  return { deployer: d, owner: o, operator: p };
}

/** Per-chain overrides for the plan (bond floors). Refuses a chain with no entry rather than guessing. */
export function chainParams(chainName) {
  const c = read("v2.chains.json").chains[chainName];
  if (!c) throw new Error(`config/v2.chains.json has no entry for ${chainName}; run scripts/v2-params.mjs`);
  return { minBond: c.minBond, arbiterMinBond: c.arbiterMinBond };
}

/** The key file for a real v2 broadcast: must be given explicitly and must not be the v1 deployer's directory. */
export function v2KeyFile(path) {
  if (!path) throw new Error("v2 --broadcast needs --key-file <path to the NEW v2 deployer json>");
  if (path.includes(".predge-deployer")) throw new Error("refusing to use a key from ~/.predge-deployer for v2");
  return path;
}
