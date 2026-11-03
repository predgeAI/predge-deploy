// Network and key guards, contract loading and small chain helpers.
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ContractFactory, ethers } from "ethers";

export const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

export const ANVIL_CHAIN_ID = 31337;
export const ARC_TESTNET = Object.freeze({
  chainId: 5042002,
  rpc: "https://rpc.testnet.arc.network",
  usdc: "0x3600000000000000000000000000000000000000",
  explorer: "https://testnet.arcscan.app",
});
const ALLOWED_CHAINS = new Set([ANVIL_CHAIN_ID, ARC_TESTNET.chainId]);

/** Public addresses of the deployers of the live contract set (see deployments/). They must never sign here. */
export const FORBIDDEN_KEYS = Object.freeze([
  "0x5d016C1B4d7A42eB7c982da1Ae7fFdB958CFCAe9",
  "0x33275DDdb0cB5Bc120740e048B030F107F144Ac8",
  "0x555F7Db71f5b71A36bD6e5EE4dEba5D784f88a2A",
  "0xbB7A0c24677339045434273FFC2266B99E1e1301",
]);

export const isLocalRpc = (url) => {
  const host = new URL(url).hostname;
  return host === "127.0.0.1" || host === "localhost" || host === "[::1]";
};

export const CONFIRM_VALUE = "arc-testnet";

/**
 * Called before anything can be signed. Writing always needs `--broadcast`. A remote RPC must be Arc testnet,
 * and writing to it also needs CONFIRM_TESTNET=arc-testnet.
 */
export async function guardNetwork(provider, rpcUrl, { broadcast = false } = {}) {
  const chainId = Number((await provider.getNetwork()).chainId);
  if (!ALLOWED_CHAINS.has(chainId)) throw new Error(`chain ${chainId} is not allowed: this demo runs on anvil or Arc testnet only`);
  if (isLocalRpc(rpcUrl)) return { chainId, canWrite: broadcast, local: true };
  if (chainId !== ARC_TESTNET.chainId) throw new Error(`remote chain ${chainId} is not Arc testnet`);
  const canWrite = broadcast && process.env.CONFIRM_TESTNET === CONFIRM_VALUE;
  if (broadcast && !canWrite) throw new Error(`--broadcast on a remote RPC also needs CONFIRM_TESTNET=${CONFIRM_VALUE}`);
  return { chainId, canWrite, local: false };
}

/** Refuses a known mainnet deployer however it got here. */
export function guardKey(wallet) {
  if (FORBIDDEN_KEYS.some((a) => a.toLowerCase() === wallet.address.toLowerCase())) {
    throw new Error(`${wallet.address} is a mainnet deployer. Use fresh testnet-only keys.`);
  }
  return wallet;
}

export const KEYS_FILE = process.env.JOB_ESCROW_KEYS || join(homedir(), ".predge-job-escrow", "keys.json");

/** Fresh testnet keys made by keygen.mjs, outside the repo, mode 600. */
export function loadKeys(provider, file = KEYS_FILE) {
  if (!existsSync(file)) throw new Error(`no keys at ${file}. Run: npm run job-escrow:keygen`);
  const j = JSON.parse(readFileSync(file, "utf8"));
  const wallet = (name) => {
    if (!j[name]?.privateKey) throw new Error(`${file} has no ${name} key`);
    return guardKey(new ethers.Wallet(j[name].privateKey, provider));
  };
  return { owner: wallet("owner"), operator: wallet("operator"), buyer: wallet("buyer"), refundTo: wallet("refundTo"), seller: wallet("seller") };
}

function artifact(file, name = file) {
  const p = join(REPO_ROOT, "build-v2/out", `${file}.sol`, `${name}.json`);
  if (!existsSync(p)) throw new Error(`no artifact ${p}. Run: FOUNDRY_CONFIG=foundry-v2.toml forge build`);
  const j = JSON.parse(readFileSync(p, "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}

export const artifacts = () => ({
  escrow: artifact("PredgeJobEscrow"),
  arbiter: artifact("PredgeRefundArbiterV2"),
  usdc: artifact("MockUSDC"),
});

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)",
];

export function attach({ escrow, arbiter, usdc }, runner) {
  const a = artifacts();
  return {
    escrow: new ethers.Contract(escrow, a.escrow.abi, runner),
    arbiter: new ethers.Contract(arbiter, a.arbiter.abi, runner),
    usdc: new ethers.Contract(usdc, ERC20_ABI, runner),
  };
}

export async function deploy(signer, name, ...args) {
  const a = artifacts()[name];
  const c = await new ContractFactory(a.abi, a.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}

/**
 * Escrow -> arbiter -> bind: the arbiter's `refundProtocol` is immutable, so the escrow must exist first.
 * The arbiter source is PredgeRefundArbiterV2 unchanged; this is a fresh instance with its own roles.
 */
export async function deployEscrowSet(deployer, { usdc, owner, operator, window = 3600n, minBond = 5n * 10n ** 18n, bps = 0 }) {
  const escrow = await deploy(deployer, "escrow", usdc);
  const arbiter = await deploy(deployer, "arbiter", owner, operator, await escrow.getAddress(), window, minBond, bps);
  await (await escrow.bind(await arbiter.getAddress())).wait();
  return { escrow: await escrow.getAddress(), arbiter: await arbiter.getAddress(), usdc };
}

export async function chainNow(provider) {
  return BigInt((await provider.getBlock("latest")).timestamp);
}

/** Decodes a revert to its custom error name when it is one of ours. */
export function revertName(err, ...contracts) {
  const data = err?.data ?? err?.info?.error?.data ?? err?.error?.data;
  if (typeof data === "string") {
    for (const c of contracts) {
      try {
        const parsed = c.interface.parseError(data);
        if (parsed) return parsed.name;
      } catch {
        /* not this contract's error */
      }
    }
  }
  return err?.shortMessage ?? err?.message ?? String(err);
}

export const RulingStatus = Object.freeze({ None: 0n, Ruled: 1n, Disputed: 2n, Finalized: 3n, Overturned: 4n, Voided: 5n });
export const JobState = Object.freeze({ None: 0n, Funded: 1n, Released: 2n, Refunded: 3n });

export const fmtUsdc = (units) => `${ethers.formatUnits(units, 6)} USDC`;
