import { readFileSync } from "node:fs";
import { JsonRpcProvider, Network } from "ethers";

export const CHAINS = JSON.parse(readFileSync(new URL("../config/chains.json", import.meta.url), "utf8"));
export const SET = JSON.parse(readFileSync(new URL("../config/set.json", import.meta.url), "utf8"));

export function chainConfig(name) {
  const c = CHAINS[name];
  if (!c) throw new Error(`unknown chain "${name}". Known: ${Object.keys(CHAINS).join(", ")}`);
  return { name, ...c };
}

export async function rawRpc(url, method, params = [], timeoutMs = 20000) {
  const r = await fetch(url, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message || JSON.stringify(j.error)}`);
  return j.result;
}

/** First RPC in the list that answers with the expected chainId. */
export async function pickRpc(chain, override) {
  const urls = override ? [override] : chain.rpc;
  for (const url of urls) {
    try {
      const id = parseInt(await rawRpc(url, "eth_chainId"), 16);
      if (id === chain.chainId) return url;
      console.warn(`  ${url} answered chainId ${id}, expected ${chain.chainId}; skipping`);
    } catch (e) {
      console.warn(`  ${url} unreachable (${String(e.message).slice(0, 80)})`);
    }
  }
  throw new Error(`no working RPC for ${chain.name}`);
}

export function providerFor(url, chainId) {
  return new JsonRpcProvider(url, undefined, { staticNetwork: Network.from(chainId), batchMaxCount: 1, polling: true, pollingInterval: 1000, cacheTimeout: -1 });
}

export async function withRetry(label, fn, tries = 5) {
  let last;
  for (let i = 0; i < tries; i++) {
    try { return await fn(); } catch (e) {
      last = e;
      const msg = String(e?.shortMessage || e?.message || e);
      if (/revert|CALL_EXCEPTION|nonce|insufficient funds|already known|replacement/i.test(msg)) throw e;
      await new Promise((r) => setTimeout(r, 1500 * (i + 1)));
    }
  }
  throw new Error(`${label}: ${last?.shortMessage || last?.message || last}`);
}

/** Receipt polling that tolerates RPC errors (a fork forwards unknown hashes upstream, which may 403). */
export async function waitReceipt(provider, hash, timeoutMs = 180000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    try { const r = await provider.getTransactionReceipt(hash); if (r) return r; } catch {}
    await new Promise((r) => setTimeout(r, 750));
  }
  throw new Error(`no receipt for ${hash} after ${timeoutMs / 1000}s`);
}
