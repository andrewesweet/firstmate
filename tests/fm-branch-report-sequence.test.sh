#!/usr/bin/env bash
# Drives the shared report/processed decision core (lib/fm-branch-report-sequence.ts)
# and the shared provider-error latch (lib/fm-branch-provider-latch.ts) from
# the two hosts that consume them plus their vendored copies, on one fixture
# set (A4 of the supervision-branch hexagon refactor):
#   - the mod leg: the REAL Claude Code supervision-branch tool handlers
#     (.claude/mods/fm-branch-mod/hooks/branch.ts serveReport/serveProcessed),
#     bound through the exported bind() with a capturing process runner, and
#     the real latch wiring assertions live in the mod's own engine test
#     (tests/fm-branch-claude-mod-plugin.test.sh) because the latch is driven
#     from turn hooks that only that host can drive;
#   - the lib leg: the shared modules the Pi extension imports, driven through
#     the same handler logic the extension calls; the Pi host's own seams (the
#     isError scoping-refusal shape, the wakeScopeRefusal wording, the through
#     coercion, and the reconcile mark-read failure text) are pinned
#     behaviorally by tests/fm-pi-branch-extension.test.sh against the real
#     extension, so this suite pins the shared core and the mod leg;
#   - the vendored legs: the same drivers against
#     .claude/mods/fm-branch-mod/lib/fm-branch-report-sequence.ts and
#     fm-branch-provider-latch.ts, which must decide byte-identically.
# The lib and mod legs must agree on every admission/refusal verdict, its
# error shape, and the exact store argv transcript (append/mark-read/
# mark-processed), including the module-owned texts byte-for-byte; the
# per-host refusal and failure strings are pinned to the mod's current
# wording because zero behaviour change is this refactor's contract. The
# latch schedules pin the threshold, first-latch cooldown, doubling with the
# cap, probe admission/commit/settle semantics, and recovery for both hosts'
# policies, byte-equal between lib and vendored copies.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-report-sequence)

# ---------- fixture plan (one set, driven through every leg) -----------------
PLAN='[
 {"kind":"inflight","value":{"tasks":["ship-a","ship-b"],"heartbeat":false,"wakeKey":"","reportedSeqs":[]}},
 {"kind":"report","input":{"task":"","verdict":"routine","summary":"x","silent":false}},
 {"kind":"report","input":{"task":"ship-a","verdict":"maybe","summary":"x","silent":false}},
 {"kind":"report","input":{"task":"ship-a","verdict":"captain","summary":"x","silent":true}},
 {"kind":"report","input":{"task":"ship-a","verdict":"routine","summary":"","silent":false}},
 {"kind":"report","input":{"task":"fleet","verdict":"captain","summary":"x","silent":true}},
 {"kind":"report","input":{"task":"other-task","verdict":"routine","summary":"x","silent":false}},
 {"kind":"report","input":{"task":"ship-a","verdict":"routine","summary":"did the thing","silent":false,"wake":"heartbeat: fleet-wide nothing-to-do"}},
 {"kind":"inflight","value":{"tasks":["ship-a"],"heartbeat":false,"wakeKey":"9:12","reportedSeqs":[]}},
 {"kind":"report","input":{"task":"ship-a","verdict":"captain","summary":"found a thing","silent":false,"wake":"stale: flake"}},
 {"kind":"inflight","value":{"tasks":["ship-a"],"heartbeat":true,"wakeKey":"","reportedSeqs":[]}},
 {"kind":"report","input":{"task":"ship-a","verdict":"captain","summary":"heartbeats skip scoping","silent":false}},
 {"kind":"inflight","value":{"tasks":["ship-a"],"heartbeat":false,"wakeKey":"","reportedSeqs":[]}},
 {"kind":"script","results":[{"exitCode":0,"stdout":"7","stderr":""},{"exitCode":2,"stdout":"","stderr":"mock mark-read failure"}]},
 {"kind":"report","input":{"task":"ship-a","verdict":"routine","summary":"mark-read fails","silent":false}},
 {"kind":"inflight","value":{"tasks":["ship-a"],"heartbeat":false,"wakeKey":"","reportedSeqs":[]}},
 {"kind":"script","results":[{"exitCode":2,"stdout":"","stderr":"mock append failure"}]},
 {"kind":"report","input":{"task":"ship-a","verdict":"routine","summary":"append fails","silent":false}},
 {"kind":"processed","through":5},
 {"kind":"processed","through":"8"},
 {"kind":"processed","through":0},
 {"kind":"processed","through":-2},
 {"kind":"processed","through":2.5},
 {"kind":"processed","through":"x"},
 {"kind":"script","results":[{"exitCode":0,"stdout":"","stderr":""}]},
 {"kind":"processed","through":9},
 {"kind":"script","results":[{"exitCode":3,"stdout":"","stderr":"mock store write failure"}]},
 {"kind":"processed","through":9}
]'

# The mod's duplicate-report guard is a host-only mechanic (no shared-module
# involvement), so it runs alone against the real handler with a pre-planted
# in-flight record.
DUP_PLAN='[
 {"kind":"inflight","value":{"tasks":["ship-a"],"heartbeat":false,"wakeKey":"","reportedSeqs":[4]}},
 {"kind":"report","input":{"task":"ship-a","verdict":"routine","summary":"duplicate","silent":false}}
]'

# ---------- node drivers -----------------------------------------------------
cat > "$TMP_ROOT/lib-report.mjs" <<'DRIVER'
// Drives a report-sequence module (lib or vendored) through the fixture plan,
// replaying each host's declared host seams the same way so the legs are
// comparable: admission/refusal class, error shape, and the exact argv
// transcript. The runner maps raw process results to {ok, stdout, detail}
// exactly like the mod's outcome() host seam, so module-owned failure texts
// are byte-comparable across legs. Host-owned texts are never emitted here.
import { pathToFileURL } from "node:url";
const modulePath = process.argv[2];
const plan = JSON.parse(process.argv[3]);
const m = await import(pathToFileURL(modulePath).href);
const calls = [];
let scripted = [];
const run = async (argv) => {
  calls.push(argv);
  const r = scripted.shift() ?? { exitCode: 0, stdout: "1", stderr: "" };
  return r.exitCode === 0
    ? { ok: true, stdout: r.stdout.trim(), detail: "" }
    : { ok: false, stdout: "", detail: `fm-branch-outcome.sh exited ${r.exitCode}: ${r.stderr.trim()}` };
};
let inflight = null;
const out = [];
for (const step of plan) {
  const before = calls.length;
  if (step.kind === "inflight") {
    inflight = step.value;
    continue;
  }
  if (step.kind === "script") {
    scripted.push(...step.results);
    continue;
  }
  if (step.kind === "processed") {
    const through = Number(step.through);
    if (!m.validateThroughValue(through)) {
      out.push({ denied: true, cls: "host:through-refused", argv: calls.slice(before) });
    } else {
      const r = await m.runSettlementStep(run, m.markProcessedArgv(through));
      if (!r.ok) out.push({ denied: true, cls: "host:processed-failed", argv: calls.slice(before) });
      else out.push({ denied: false, cls: "host:processed-success", argv: calls.slice(before) });
    }
    continue;
  }
  // report step
  const input = step.input;
  const validated = m.validateBranchReport(input);
  if (!validated.valid) {
    out.push({ denied: true, cls: "module:invalid", moduleText: m.INVALID_REPORT_MESSAGE, argv: calls.slice(before) });
    continue;
  }
  const scope = m.reportTaskScopeVerdict(
    inflight && !inflight.heartbeat ? { rows: [], tasks: inflight.tasks } : null,
    input.task,
  );
  if (!scope.allowed) {
    out.push({ denied: true, cls: "host:scope-refused", argv: calls.slice(before) });
    continue;
  }
  const wk = inflight && inflight.wakeKey;
  const extra = wk && /^[0-9:,]+$/.test(wk) ? ["--wake-key", wk] : undefined;
  const appended = await m.runSettlementStep(run, m.reportAppendArgv(validated, input.wake || null, extra));
  if (!appended.ok) {
    out.push({ denied: true, cls: "module:append-failed", moduleText: m.appendFailureMessage(appended.detail), argv: calls.slice(before) });
    continue;
  }
  const seq = Number(appended.stdout);
  const marked = await m.runSettlementStep(run, m.markReadArgv(seq));
  if (!marked.ok) {
    out.push({ denied: true, cls: "host:markread-failed", argv: calls.slice(before) });
    continue;
  }
  out.push({ denied: false, cls: "module:report-success", moduleText: m.reportSuccessMessage(seq, validated.verdict), argv: calls.slice(before) });
}
console.log(JSON.stringify(out));
DRIVER

cat > "$TMP_ROOT/mod-report.mjs" <<'DRIVER'
// Drives the REAL mod tool handlers (serveReport/serveProcessed) through the
// same fixture plan, with a capturing process runner so the argv transcript
// is the one the mod would hand fm-branch-outcome.sh. Verdicts are
// classified by the module-owned prefixes plus the mod's own stable host
// prefixes; every text is recorded verbatim for the bash-side assertions.
import { pathToFileURL } from "node:url";
const root = process.env.FM_RS_ROOT;
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
const vmod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/lib/fm-branch-report-sequence.ts`).href);
const plan = JSON.parse(process.argv[2]);
const calls = [];
let scripted = [];
const $ = {
  plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
  env: { get: async (name) => process.env[name] ?? "" },
  session: { cwd: async () => process.cwd() },
  fs: {
    exists: async () => false,
    read: async () => { throw new Error("no file"); },
    write: async () => {},
    append: async () => {},
    mkdir: async () => {},
    rm: async () => {},
    readDir: async () => [],
  },
  ui: { log: () => {} },
  prompt: { submit: async () => {} },
  process: {
    run: async (argv) => {
      // Only fm-branch-outcome.sh calls are part of the transcript and the
      // scripted-result queue; the mod's event-log appends ride the same
      // $.process.run seam and are answered silently.
      if (argv[0] === "bash" && String(argv[1] ?? "").endsWith("fm-branch-outcome.sh")) {
        calls.push(argv.slice(2));
        return scripted.shift() ?? { exitCode: 0, stdout: "1", stderr: "" };
      }
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  },
};
await mod.bind($, process.cwd());
const HOST_PREFIXES = [
  ["host:markread-failed", /^recorded seq [0-9]+, but cursor advancement failed: /],
  ["host:scope-refused", /^report not recorded: task must be /],
  ["host:processed-failed", /^processed marker not advanced: /],
  ["host:through-refused", /^through must be a positive integer$/],
  ["host:duplicate", /^already recorded seq [0-9]+ for this wake; /],
];
function classify(text) {
  if (text === vmod.INVALID_REPORT_MESSAGE) return "module:invalid";
  if (/^outcome store append failed \(nothing merged\): /.test(text)) return "module:append-failed";
  if (/^recorded seq [0-9]+ and delivered \[(routine|captain)\] into main$/.test(text)) return "module:report-success";
  if (/^captain outcomes through seq [0-9]+ marked processed$/.test(text)) return "host:processed-success";
  for (const [cls, re] of HOST_PREFIXES) if (re.test(text)) return cls;
  return "UNEXPECTED:" + text;
}
const out = [];
for (const step of plan) {
  if (step.kind === "inflight") {
    const v = step.value;
    mod.__fmSetInFlight({
      seqs: [],
      wakeKey: v.wakeKey,
      tasks: new Set(v.tasks),
      heartbeat: v.heartbeat,
      wakeText: "",
      reason: "",
      reportedSeqs: [...v.reportedSeqs],
      startedAt: 0,
      granted: false,
      wakeNo: 1,
      via: "spawn",
    });
    continue;
  }
  if (step.kind === "script") {
    scripted.push(...step.results);
    continue;
  }
  const before = calls.length;
  const r = step.kind === "processed"
    ? await mod.serveProcessed($, { through: step.through })
    : await mod.serveReport($, step.input, undefined);
  out.push({
    denied: "deny" in r,
    cls: classify(r.result ?? r.deny),
    text: r.result ?? r.deny,
    argv: calls.slice(before),
  });
}
console.log(JSON.stringify(out));
DRIVER

cat > "$TMP_ROOT/latch-run.mjs" <<'DRIVER'
// Drives one provider-error latch module through one policy and one schedule
// with an injected clock, emitting one deterministic JSON verdict per step.
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.argv[2]).href);
const policy = JSON.parse(process.argv[3]);
const schedule = JSON.parse(process.argv[4]);
let t = 0;
const latch = mod.createProviderErrorLatch(policy, () => t);
const out = [];
for (const step of schedule) {
  t = step.t;
  let v;
  switch (step.a) {
    case "fail": v = { a: step.a, ...latch.recordFailure() }; break;
    case "success": v = { a: step.a, ...latch.recordSuccess() }; break;
    case "admit": v = { a: step.a, ...latch.admitWake() }; break;
    case "begin": latch.beginProbe(); v = { a: step.a, probing: latch.isProbing() }; break;
    case "finish": latch.finishProbe(); v = { a: step.a, probing: latch.isProbing(), armed: latch.isArmed() }; break;
    case "reset": latch.reset(); v = { a: step.a, armed: latch.isArmed(), probing: latch.isProbing() }; break;
    default: throw new Error(`unknown schedule action ${step.a}`);
  }
  out.push(v);
}
console.log(JSON.stringify(out));
DRIVER

export FM_RS_ROOT="$ROOT"
export FM_ROOT_OVERRIDE="$TMP_ROOT"

# ---------- run the legs ------------------------------------------------------
node "$TMP_ROOT/lib-report.mjs" "$ROOT/lib/fm-branch-report-sequence.ts" "$PLAN" > "$TMP_ROOT/lib.json"
node "$TMP_ROOT/lib-report.mjs" "$ROOT/.claude/mods/fm-branch-mod/lib/fm-branch-report-sequence.ts" "$PLAN" > "$TMP_ROOT/vendored.json"
node "$TMP_ROOT/mod-report.mjs" "$PLAN" > "$TMP_ROOT/mod.json"
node "$TMP_ROOT/mod-report.mjs" "$DUP_PLAN" > "$TMP_ROOT/mod-dup.json"

# ---------- verdict + argv agreement between mod and lib ---------------------
# Same steps, same admission/refusal class, same error shape, same argv. The
# scoping refusal's ERROR SHAPE is the declared D1 host seam (the Pi tool
# returns isError; the mod returns a normal result), so denied is compared on
# every row except host:scope-refused; its refusal RULE and argv are compared
# everywhere.
jq -c '.[] | {cls, denied: (if .cls == "host:scope-refused" then null else .denied end), argv}' "$TMP_ROOT/mod.json" > "$TMP_ROOT/mod.norm"
jq -c '.[] | {cls, denied: (if .cls == "host:scope-refused" then null else .denied end), argv}' "$TMP_ROOT/lib.json" > "$TMP_ROOT/lib.norm"
if cmp -s "$TMP_ROOT/mod.norm" "$TMP_ROOT/lib.norm"; then
  pass "mod tool handlers and lib decide identically on every fixture (verdict, error shape, argv transcript)"
else
  diff "$TMP_ROOT/lib.norm" "$TMP_ROOT/mod.norm" >&2 || true
  fail "mod and lib verdict/argv transcripts diverge"
fi

# ---------- vendored copies decide byte-identically to lib --------------------
if cmp -s "$TMP_ROOT/lib.json" "$TMP_ROOT/vendored.json"; then
  pass "vendored report-sequence copy is byte-identical to lib on every fixture"
else
  fail "vendored report-sequence copy diverges from lib"
fi

# ---------- module-owned texts are the same bytes in both hosts ---------------
jq -c '[.[] | select(.cls | startswith("module:")) | {cls, text}]' "$TMP_ROOT/mod.json" > "$TMP_ROOT/mod.module-texts"
jq -c '[.[] | select(.cls | startswith("module:")) | {cls, text: .moduleText}]' "$TMP_ROOT/lib.json" > "$TMP_ROOT/lib.module-texts"
if [ -s "$TMP_ROOT/mod.module-texts" ] && cmp -s "$TMP_ROOT/mod.module-texts" "$TMP_ROOT/lib.module-texts"; then
  pass "module-owned texts are byte-identical between mod and lib"
else
  fail "module-owned texts diverge between mod and lib"
fi

# ---------- host seam strings: the mod's current wording is pinned ------------
if grep -q 'report not recorded: task must be ship-a or ship-b (this wake'"'"'s own task), not '"'"'other-task'"'"'. Call fm_branch_report again with task=ship-a and the same verdict and summary.' "$TMP_ROOT/mod.json"; then
  pass "mod task-scope refusal keeps its host wording (insertion order + corrective re-report)"
else
  fail "mod task-scope refusal wording changed"
fi

if grep -q 'recorded seq 7, but cursor advancement failed: fm-branch-outcome.sh exited 2: mock mark-read failure' "$TMP_ROOT/mod.json"; then
  pass "mod mark-read failure keeps its host wording"
else
  fail "mod mark-read failure wording changed"
fi

if grep -q 'captain outcomes through seq 9 marked processed' "$TMP_ROOT/mod.json" &&
  grep -q 'captain outcomes through seq 8 marked processed' "$TMP_ROOT/mod.json"; then
  pass "mod processed success keeps its host wording for numeric and string inputs"
else
  fail "mod processed success wording changed"
fi

if grep -q 'through must be a positive integer' "$TMP_ROOT/mod.json"; then
  pass "mod through refusal keeps its host wording"
else
  fail "mod through refusal wording changed"
fi

if grep -q 'already recorded seq 4 for this wake' "$TMP_ROOT/mod-dup.json"; then
  pass "mod duplicate-report guard (host-only mechanic) still fires"
else
  fail "mod duplicate-report guard did not fire"
fi

# The shared through rule must refuse 0, -2, 2.5, and non-numeric input
# through the mod's Number() coercion, while string "8" is accepted.
if jq -e '[.[] | select(.cls == "host:through-refused")] | length == 4' "$TMP_ROOT/mod.json" >/dev/null; then
  pass "shared through rule refuses 0, -2, 2.5, and non-numeric through the mod"
else
  fail "mod through refusal count wrong"
fi

# ---------- latch schedules ---------------------------------------------------
PI_SCHEDULE='[
 {"a":"fail","t":0},
 {"a":"admit","t":1},
 {"a":"fail","t":1000},
 {"a":"admit","t":2000},
 {"a":"admit","t":301000},
 {"a":"begin","t":301000},
 {"a":"admit","t":301001},
 {"a":"fail","t":305000},
 {"a":"finish","t":305000},
 {"a":"admit","t":600000},
 {"a":"admit","t":905000},
 {"a":"begin","t":905000},
 {"a":"success","t":906000},
 {"a":"finish","t":906000},
 {"a":"admit","t":907000},
 {"a":"fail","t":907000},
 {"a":"fail","t":908000},
 {"a":"reset","t":908001},
 {"a":"admit","t":908002}
]'
MOD_SCHEDULE='[
 {"a":"fail","t":0},
 {"a":"fail","t":1000},
 {"a":"admit","t":2000},
 {"a":"admit","t":301000},
 {"a":"begin","t":301000},
 {"a":"fail","t":301001},
 {"a":"admit","t":601001},
 {"a":"admit","t":601002},
 {"a":"success","t":601003}
]'

run_latch() { # module policy schedule outfile
  node "$TMP_ROOT/latch-run.mjs" "$1" "$2" "$3" > "$4"
}

run_latch "$ROOT/lib/fm-branch-provider-latch.ts" \
  '{"threshold":2,"baseCooldownMs":300000,"maxCooldownMs":3600000,"recoveryProbe":true}' \
  "$PI_SCHEDULE" "$TMP_ROOT/pi-lib.json"
run_latch "$ROOT/.claude/mods/fm-branch-mod/lib/fm-branch-provider-latch.ts" \
  '{"threshold":2,"baseCooldownMs":300000,"maxCooldownMs":3600000,"recoveryProbe":true}' \
  "$PI_SCHEDULE" "$TMP_ROOT/pi-vendored.json"
run_latch "$ROOT/lib/fm-branch-provider-latch.ts" \
  '{"threshold":2,"baseCooldownMs":300000,"maxCooldownMs":300000,"recoveryProbe":false}' \
  "$MOD_SCHEDULE" "$TMP_ROOT/modpol-lib.json"
run_latch "$ROOT/.claude/mods/fm-branch-mod/lib/fm-branch-provider-latch.ts" \
  '{"threshold":2,"baseCooldownMs":300000,"maxCooldownMs":300000,"recoveryProbe":false}' \
  "$MOD_SCHEDULE" "$TMP_ROOT/modpol-vendored.json"

if cmp -s "$TMP_ROOT/pi-lib.json" "$TMP_ROOT/pi-vendored.json" && cmp -s "$TMP_ROOT/modpol-lib.json" "$TMP_ROOT/modpol-vendored.json"; then
  pass "vendored latch copy is byte-identical to lib on both host policies"
else
  fail "vendored latch copy diverges from lib"
fi

# Pin the shared machine's load-bearing schedule facts on the lib leg.
if jq -e '
  .[0] == {"a":"fail","streak":1,"armed":false,"firstLatch":false,"cooldownMs":0,"latchedUntil":0}
  and .[2] == {"a":"fail","streak":2,"armed":true,"firstLatch":true,"cooldownMs":300000,"latchedUntil":301000}
  and .[3] == {"a":"admit","decision":"latched"}
  and .[4] == {"a":"admit","decision":"probe"}
  and .[6] == {"a":"admit","decision":"latched"}
  and .[7] == {"a":"fail","streak":3,"armed":true,"firstLatch":false,"cooldownMs":600000,"latchedUntil":905000}
  and .[8] == {"a":"finish","probing":false,"armed":true}
  and .[9] == {"a":"admit","decision":"latched"}
  and .[10] == {"a":"admit","decision":"probe"}
  and .[12] == {"a":"success","recovered":true,"streak":0}
  and .[13] == {"a":"finish","probing":false,"armed":false}
  and .[14] == {"a":"admit","decision":"open"}
  and .[15] == {"a":"fail","streak":1,"armed":false,"firstLatch":false,"cooldownMs":0,"latchedUntil":0}
  and .[16] == {"a":"fail","streak":2,"armed":true,"firstLatch":true,"cooldownMs":300000,"latchedUntil":1208000}
  and .[17] == {"a":"reset","armed":false,"probing":false}
  and .[18] == {"a":"admit","decision":"open"}
' "$TMP_ROOT/pi-lib.json" >/dev/null; then
  pass "Pi latch schedule: 2 to latch, 5m base, failed probe doubles to 10m, one probe per cooldown, recovery resets"
else
  fail "Pi latch schedule diverged"
fi

if jq -e '
  .[1] == {"a":"fail","streak":2,"armed":true,"firstLatch":true,"cooldownMs":300000,"latchedUntil":301000}
  and .[2] == {"a":"admit","decision":"latched"}
  and .[3] == {"a":"admit","decision":"open"}
  and .[4] == {"a":"begin","probing":false}
  and .[5] == {"a":"fail","streak":3,"armed":true,"firstLatch":false,"cooldownMs":300000,"latchedUntil":601001}
  and .[6] == {"a":"admit","decision":"open"}
  and .[7] == {"a":"admit","decision":"open"}
  and .[8] == {"a":"success","recovered":true,"streak":0}
' "$TMP_ROOT/modpol-lib.json" >/dev/null; then
  pass "Mod latch schedule: 2 to latch, fixed 5m cooldown, doubled value capped back to 5m, no probe slot"
else
  fail "Mod latch schedule diverged"
fi
