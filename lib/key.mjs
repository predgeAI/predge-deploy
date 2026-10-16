import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { Wallet } from "ethers";

export const KEY_FILE = process.env.PREDGE_DEPLOYER_FILE || `${homedir()}/.predge-deployer/deployer.json`;

/** Loads the deployer. Refuses a key file other users can read. Never logs the key. */
export function loadDeployer(provider) {
  let st;
  try { st = statSync(KEY_FILE); } catch {
    throw new Error(`no deployer key at ${KEY_FILE}. Run: npm run keygen`);
  }
  if (st.mode & 0o077) throw new Error(`${KEY_FILE} is readable by others (mode ${(st.mode & 0o777).toString(8)}). chmod 600 it.`);
  const j = JSON.parse(readFileSync(KEY_FILE, "utf8"));
  const w = new Wallet(j.privateKey, provider);
  if (w.address !== j.address) throw new Error("deployer.json address does not match its key");
  return w;
}

export function deployerAddress() {
  return JSON.parse(readFileSync(KEY_FILE, "utf8")).address;
}
