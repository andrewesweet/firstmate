// Differential fuzz: random status logs + metas, bash status_open_decisions vs lib foldStatusLog,
// and bash last_status_line/status_is_captain_held vs lib currentDeclarationHeld.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import { pathToFileURL } from "node:url";
const root = process.env.FM_ROOT;
const lib = await import(pathToFileURL(`${root}/lib/fm-branch-eligibility.ts`).href);
let seed = Number(process.env.SEED ?? 1);
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
const pick = (a) => a[Math.floor(rnd() * a.length)];
const verbs = ["needs-decision", "blocked", "resolved", "captain-held", "done", "failed", "working", "note", "paused", "ack", "hold", "PR ready", "checks green", "Needs-Decision", "needs-decision corr=0123456789abcdef", "corr=0123456789abcdef needs-decision", "needs-decision corr=zz"];
const keys = ["dep", "a.b_c-1", "bad key", "", "pending-reply-m1", "pending-reply-x", "default", "k]x", "UPPER"];
const notes = ["pick", "pending-reply-m1: awaiting", "pending-reply-x no colon", "", "  padded  ", "waiting: on: colons", "note\r", "[key=dep] head note", "[key=bad key] x", "[key=pending-reply-m1] pending-reply-m1: ok"];
function line() {
  const r = rnd();
  if (r < 0.08) return pick(["continuation prose", "", "   ", "[key=dep]", "[key=bad key]", "needs-decision [key=dep] no colon", "merged", "  ready in branch"]);
  const v = pick(verbs);
  const k = rnd() < 0.7 ? ` [key=${pick(keys)}]` : "";
  const n = pick(notes);
  const s = rnd() < 0.3 ? "  " : "";
  return `${s}${v}${k}: ${n}`;
}
const metaKinds = [null, "kind=ship\n", "kind=scout\n", "kind=secondmate\n", "kind=other\n", "project=demo\n", "kind=ship\r\n", "kind=ship\nkind=scout\n", "SYMLINK", "kind=\n"];
const N = Number(process.env.N ?? 300);
let mismatches = 0; const stats={ne:0,h:0};
for (let i = 0; i < N; i++) {
  const dir = `/tmp/fmelig/fz/${i}`;
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const n = 1 + Math.floor(rnd() * 8);
  const lines = Array.from({ length: n }, line);
  const eol = rnd() < 0.15 ? "\r\n" : "\n";
  const text = lines.join(eol) + (rnd() < 0.8 ? eol : "");
  writeFileSync(`${dir}/t.status`, text);
  const mk = pick(metaKinds);
  if (mk === "SYMLINK") { writeFileSync(`${dir}/real.meta`, "kind=ship\n"); symlinkSync("real.meta", `${dir}/t.meta`); }
  else if (mk !== null) writeFileSync(`${dir}/t.meta`, mk);
  const env = { ...process.env };
  if (rnd() < 0.2) { env.FM_CLASSIFY_RESOLVE_VERB = "ack"; env.FM_CLASSIFY_CAPTAIN_HELD_VERB = "hold"; }
  if (rnd() < 0.2) env.FM_CLASSIFY_RESERVED_KEY_PREFIXES = "pending-reply- dep";
  if (rnd() < 0.2) env.FM_CLASSIFY_PAUSED_VERB = "hold";
  const bashFold = execFileSync("bash", ["-c", '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2/t.status"', "_", root, dir], { env, encoding: "utf8" });
  const bashHeld = execFileSync("bash", ["-c", '. "$1/bin/fm-classify-lib.sh"; l=$(last_status_line "$2/t.status"); status_is_captain_held "$l" && echo held || echo free', "_", root, dir], { env, encoding: "utf8" }).trim();
  const saved = { ...process.env };
  for (const k of ["FM_CLASSIFY_RESOLVE_VERB", "FM_CLASSIFY_CAPTAIN_HELD_VERB", "FM_CLASSIFY_RESERVED_KEY_PREFIXES", "FM_CLASSIFY_PAUSED_VERB"]) { delete process.env[k]; if (env[k]) process.env[k] = env[k]; }
  const libFold = lib.foldStatusLog(dir, "t");
  const vocab = lib.foldVocabularyFromEnv((k) => process.env[k]);
  const libHeld = lib.currentDeclarationHeld(text.split("\n").filter((l) => /\S/.test(l)), vocab) ? "held" : "free";
  process.env = saved;
  if (bashFold) stats.ne++; if (bashHeld==="held") stats.h++;
  if (bashFold !== libFold || bashHeld !== libHeld) {
    mismatches++;
    console.log(`MISMATCH #${i} meta=${JSON.stringify(mk)} env=${JSON.stringify({r:env.FM_CLASSIFY_RESOLVE_VERB,h:env.FM_CLASSIFY_CAPTAIN_HELD_VERB,p:env.FM_CLASSIFY_RESERVED_KEY_PREFIXES,pv:env.FM_CLASSIFY_PAUSED_VERB})}\nlog=${JSON.stringify(text)}\nbash=${JSON.stringify(bashFold)} held=${bashHeld}\nlib =${JSON.stringify(libFold)} held=${libHeld}\n`);
  }
}
console.log(`nonempty=${stats.ne} held=${stats.h} cases=${N} mismatches=${mismatches}`);
process.exit(mismatches ? 1 : 0);
