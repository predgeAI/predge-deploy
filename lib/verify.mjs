// Source verification. Order: Etherscan v2 multichain (ETHERSCAN_API_KEY) or the chain's Blockscout,
// then Sourcify (no key). Anything that cannot be verified is returned as a TODO, never hidden.
const ETHERSCAN_V2 = "https://api.etherscan.io/v2/api";
const SOURCIFY = "https://sourcify.dev/server";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function etherscanLike(base, { chainId, apiKey, step, txHash }) {
  const c = step.compiled;
  const params = new URLSearchParams({
    module: "contract", action: "verifysourcecode",
    contractaddress: step.address,
    sourceCode: JSON.stringify(c.input),
    codeformat: "solidity-standard-json-input",
    contractname: `${step.name}.sol:${step.name}`,
    compilerversion: c.compilerVersion,
    constructorArguements: step.constructorArgs.replace(/^0x/, ""),
    constructorArguments: step.constructorArgs.replace(/^0x/, ""),
  });
  if (apiKey) params.set("apikey", apiKey);
  const url = base.includes("etherscan.io/v2") ? `${base}?chainid=${chainId}` : base;
  const r = await (await fetch(url, { method: "POST", body: params, headers: { "content-type": "application/x-www-form-urlencoded" } })).json();
  if (r.status !== "1") {
    if (/already verified/i.test(r.result || r.message)) return { ok: true, via: base, note: "already verified" };
    return { ok: false, via: base, error: r.result || r.message };
  }
  const guid = r.result;
  for (let i = 0; i < 20; i++) {
    await sleep(5000);
    const q = new URLSearchParams({ module: "contract", action: "checkverifystatus", guid });
    if (apiKey) q.set("apikey", apiKey);
    const s = await (await fetch(`${base.includes("etherscan.io/v2") ? `${base}?chainid=${chainId}&` : `${base}?`}${q}`)).json();
    if (/pass|verified/i.test(s.result) && !/fail/i.test(s.result)) return { ok: true, via: base, guid };
    if (!/pending|queue/i.test(s.result)) return { ok: false, via: base, error: s.result };
  }
  return { ok: false, via: base, error: "timeout waiting for verification" };
}

async function sourcify({ chainId, step, txHash }) {
  const c = step.compiled;
  const r = await fetch(`${SOURCIFY}/v2/verify/${chainId}/${step.address}`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ stdJsonInput: c.input, compilerVersion: c.compilerVersion.replace(/^v/, ""), contractIdentifier: `${step.name}.sol:${step.name}`, creationTransactionHash: txHash }),
  });
  const j = await r.json().catch(() => ({}));
  if (r.status === 409) return { ok: true, via: "sourcify", note: "already verified" };
  if (!j.verificationId) return { ok: false, via: "sourcify", error: j.message || j.customCode || `HTTP ${r.status}` };
  for (let i = 0; i < 20; i++) {
    await sleep(4000);
    const s = await (await fetch(`${SOURCIFY}/v2/verify/${j.verificationId}`)).json();
    if (s.isJobCompleted) return s.error ? { ok: false, via: "sourcify", error: s.error.message } : { ok: true, via: "sourcify", match: s.contract?.match };
  }
  return { ok: false, via: "sourcify", error: "timeout" };
}

export async function verifyStep(chain, step, txHash) {
  const tried = [];
  const key = process.env.ETHERSCAN_API_KEY;
  if (chain.verify?.kind === "etherscan-v2" && key) {
    const r = await etherscanLike(ETHERSCAN_V2, { chainId: chain.chainId, apiKey: key, step, txHash }).catch((e) => ({ ok: false, error: e.message }));
    if (r.ok) return r; tried.push(r);
  } else if (chain.verify?.kind === "etherscan-v2") {
    tried.push({ ok: false, via: "etherscan-v2", error: "ETHERSCAN_API_KEY not set" });
  }
  if (chain.verify?.kind === "blockscout") {
    const r = await etherscanLike(chain.verify.api, { chainId: chain.chainId, step, txHash }).catch((e) => ({ ok: false, error: e.message }));
    if (r.ok) return r; tried.push(r);
  }
  const s = await sourcify({ chainId: chain.chainId, step, txHash }).catch((e) => ({ ok: false, via: "sourcify", error: e.message }));
  if (s.ok) return s;
  tried.push(s);
  return { ok: false, todo: `verify ${step.name} at ${step.address} on ${chain.explorer} (standard-json in deployments/verify/${step.name}.json)`, tried };
}
