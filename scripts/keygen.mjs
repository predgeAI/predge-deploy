// Create the dedicated Predge deployer key. Prints the ADDRESS only, never the key.
// The key lives at ~/.predge-deployer/deployer.json (dir 0700, file 0600) and is never committed.
import { existsSync, mkdirSync, writeFileSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { Wallet } from "ethers";

const DIR = process.env.PREDGE_DEPLOYER_DIR || `${homedir()}/.predge-deployer`;
const FILE = `${DIR}/deployer.json`;
if (existsSync(FILE)) {
  console.error(`${FILE} already exists. Refusing to overwrite a deployer key (addresses depend on it).`);
  process.exit(1);
}
mkdirSync(DIR, { recursive: true, mode: 0o700 });
chmodSync(DIR, 0o700);
const w = Wallet.createRandom();
writeFileSync(FILE, JSON.stringify({
  address: w.address,
  privateKey: w.privateKey,
  createdAt: new Date().toISOString(),
  purpose: "Predge canonical multi-chain deployer. Use ONLY via predge-deploy: any other tx shifts the nonce and breaks same-address deploys on that chain.",
}, null, 2) + "\n", { mode: 0o600 });
chmodSync(FILE, 0o600);
console.log(`deployer address: ${w.address}`);
console.log(`key stored at ${FILE} (0600). Back it up offline; it is not recoverable.`);
