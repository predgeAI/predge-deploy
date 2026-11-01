// A small mutation-testing smoke run for contracts/v2, so weak tests are found before an external mutation scanner finds them.
//   node scripts/mutate-v2.mjs [--with-invariants] [--only <file substring>] [--limit N]
// Each mutant changes ONE line of ONE file, runs the v2 Foundry suite, and is "killed" if any test fails. The original source is
// always restored (and re-checked with git) afterwards. Do not edit contracts/v2 while this runs.
// Operators: == <-> !=, <= < >= > swaps, && <-> ||, true <-> false, += <-> -=, and "disable this guard" (if (c) revert -> if (false && c) revert).
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";

const ROOT = new URL("../", import.meta.url).pathname;
const args = process.argv.slice(2);
const only = args.includes("--only") ? args[args.indexOf("--only") + 1] : "";
const limit = args.includes("--limit") ? Number(args[args.indexOf("--limit") + 1]) : Infinity;
const env = { ...process.env, PATH: `${homedir()}/.foundry/bin:${process.env.PATH}`, FOUNDRY_CONFIG: "foundry-v2.toml" };
const walk = (d) => readdirSync(d).flatMap((n) => { const p = `${d}/${n}`; return statSync(p).isDirectory() ? walk(p) : p.endsWith(".sol") ? [p] : []; });
const files = walk(`${ROOT}contracts/v2`).filter((f) => !f.includes("/mocks/") && f.includes(only));

const swaps = [[/ == /, " != "], [/ != /, " == "], [/ <= /, " < "], [/ < /, " <= "], [/ >= /, " > "], [/ > /, " >= "], [/ && /, " || "], [/ \|\| /, " && "], [/ \+= /, " -= "], [/ -= /, " += "], [/= true;/, "= false;"], [/= false;/, "= true;"]];
const mutants = [];
for (const f of files) {
  const lines = readFileSync(f, "utf8").split("\n");
  lines.forEach((line, i) => {
    const t = line.trim();
    if (!t || t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") || t.startsWith("pragma") || t.startsWith("import") || /^(event|error|function|modifier|constructor|struct|enum)\b/.test(t)) return;
    if (/=>/.test(line) && !/ == | != |<|>/.test(line.replace(/=>/g, ""))) return;
    for (const [re, to] of swaps) {
      if (re.test(line)) mutants.push({ f, i, op: `${re.source.trim()} -> ${to.trim()}`, text: line.replace(re, to) });
    }
    if (/^if \(.*\) revert /.test(t) || /^if \(.*\)$/.test(t) && lines[i + 1]?.trim().startsWith("revert")) mutants.push({ f, i, op: "guard disabled", text: line.replace("if (", "if (false && ") });
  });
}
const run = [...mutants].slice(0, limit);
console.log(`${run.length} mutants over ${files.length} files`);
const cmd = ["test", "-q", "--fuzz-runs", "100", ...(args.includes("--with-invariants") ? [] : ["--no-match-path", "test/foundry-v2/Invariants.t.sol"])];
let killed = 0, invalid = 0; const survivors = [];
for (const m of run) {
  const orig = readFileSync(m.f, "utf8");
  const lines = orig.split("\n"); lines[m.i] = m.text;
  writeFileSync(m.f, lines.join("\n"));
  try {
    const r = spawnSync("forge", cmd, { cwd: ROOT, env, encoding: "utf8", timeout: 600000 });
    const out = (r.stdout || "") + (r.stderr || "");
    if (/Compiler run failed|Error: Compiler/.test(out)) invalid++;
    else if (r.status !== 0) killed++;
    else { survivors.push(m); console.log(`SURVIVED ${m.f.replace(ROOT, "")}:${m.i + 1}  [${m.op}]  ${m.text.trim()}`); }
  } finally { writeFileSync(m.f, orig); }
}
const valid = run.length - invalid;
console.log(`\nkilled ${killed} / ${valid} valid mutants (${invalid} did not compile). score ${(100 * killed / Math.max(1, valid)).toFixed(1)}%. survivors ${survivors.length}`);
const dirty = spawnSync("git", ["diff", "--quiet", "--", "contracts/v2"], { cwd: ROOT }).status;
if (dirty !== 0) { console.error("WARNING: contracts/v2 differs from git after the run"); process.exit(1); }
