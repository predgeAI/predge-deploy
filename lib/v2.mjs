// v2 deployment inputs: who the roles are, and the per-chain bond floors.
//   real runs (dry-run / --broadcast): roles come from config/v2.config.json and MUST be set by the owner.
//   --fork: throwaway anvil accounts (the public anvil test keys), never touching ~/.predge-deployer or any real key.
import { readFileSync, statSync } from "node:fs";
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
  // Block the v1 deployer's directory only (path segment ".predge-deployer"), not ".predge-deployer-v2".
  if (path.split(/[\\/]/).includes(".predge-deployer")) throw new Error("refusing to use a key from ~/.predge-deployer for v2");
  return path;
}

/** Reads KEY=VALUE lines from a testnet env file (refuses one other users can read). Never logs values. */
function readEnvFile(path) {
  const st = statSync(path);
  if (st.mode & 0o077) throw new Error(`${path} is readable by others (mode ${(st.mode & 0o777).toString(8)}). chmod 600 it.`);
  const out = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

/** The mainnet identities a testnet run must never use: config/v2.config.json roles and the v1 deployer. */
function mainnetAddresses() {
  const c = read("v2.config.json");
  const s = new Set(["deployer", "owner", "operator"].map((k) => c[k]).filter(Boolean).map((a) => getAddress(a)));
  try { s.add(getAddress(JSON.parse(readFileSync(`${homedir()}/.predge-deployer/deployer.json`, "utf8")).address)); } catch {}
  return s;
}

/** Testnet chains only: throwaway roles + deployer key from the chain's env file (e.g. .env.rsk-testnet), never v2.config.json.
 *  Refuses a non-testnet chain and any address that is a mainnet Predge identity. */
export function testnetSetup(chain, rootDir, provider) {
  if (!chain.testnet || !chain.v2?.envFile) throw new Error(`${chain.name} is not a testnet chain with a v2.envFile`);
  const path = `${rootDir}${chain.v2.envFile}`;
  const env = readEnvFile(path);
  const P = chain.v2.envPrefix ?? "RSK_TESTNET_";
  const roles = {};
  for (const k of ["deployer", "owner", "operator"]) {
    const v = env[`${P}${k.toUpperCase()}_ADDRESS`];
    if (!v) throw new Error(`${path}: ${P}${k.toUpperCase()}_ADDRESS missing`);
    roles[k] = getAddress(v);
    if (ANVIL_ADDRS.has(roles[k])) throw new Error(`${path}: ${k} is a public anvil test address`);
  }
  if (new Set(Object.values(roles)).size !== 3) throw new Error(`${path}: deployer, owner and operator must differ`);
  const main = mainnetAddresses();
  for (const [k, a] of Object.entries(roles)) if (main.has(a)) throw new Error(`${path}: ${k} ${a} is a MAINNET Predge identity; testnet keys must be throwaway`);
  const loadKey = () => {
    const pk = env[`${P}DEPLOYER_PRIVATE_KEY`];
    if (!pk) throw new Error(`${path}: ${P}DEPLOYER_PRIVATE_KEY missing`);
    const w = new Wallet(pk, provider);
    if (w.address !== roles.deployer) throw new Error(`${path}: deployer key does not match ${P}DEPLOYER_ADDRESS`);
    return w;
  };
  return { roles, loadKey, path };
}
