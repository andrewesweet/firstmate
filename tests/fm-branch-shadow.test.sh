#!/usr/bin/env bash
# Colocated tests for the shared shadow-advisory module
# (.claude/mods/fm-branch-mod/lib/fm-branch-shadow.ts, the canonical copy
# the repo's lib/ symlinks to) and the mod hook's delegation. Two legs per
# fixture set: the shared module through the repo's lib/ symlink, and the
# REAL mod hook's runShadowAdvisory() driven through a mock host. The
# second must route the same module-owned bytes (results, record lines,
# request bodies, and helper spawns with the host's bind path and clock
# normalized away). Also pins: the record's field order and policy payload
# the scorers parse, the facts object the six-gate scorer reads, the jev
# answer rule, variant generation and the repeat control, bounds caps, and
# the never-throw error surface (shadow.log.error, shadow.error).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || skip "node prerequisite not found"
command -v jq >/dev/null || skip "jq prerequisite not found"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-branch-shadow)

# ---------- fixture plan (one set, driven through every leg) -----------------
# Each scenario drives one runShadowAdvisory call with its own config, state
# files (relative to each leg's state root), helper results, and wake args.
# The scenario's "config" field feeds readConfig; everything else is
# read through readFile. Helper results are consumed in order across the
# variants: pane first, then one jev call per variant.
PLAN='[
 {"name":"gate-off","config":"routine","files":{},
  "args":{"wake":"heartbeat: gate","seqs":["1"],"wakeKey":"wk-gate","tasks":["ship-a"],"wakeNo":1,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],"jev":[]},
 {"name":"single-ok","config":"jev",
  "files":{
   "ship-a.status":"## status lines appended since last outcome\n  done: compiled the fleet chart\n  blocked: waiting on the tide tables\n",
   ".ship-a.branch-outcome-index":"fm-branch-outcome-index-v1\t9\t77\tident\n",
   ".branch-outcomes-cursor":"7\n",
   "branch-outcomes.jsonl":"{\"task\":\"ship-a\",\"seq\":5,\"verdict\":\"routine\",\"summary\":\"earlier row\",\"wake\":\"heartbeat: old\"}\n{\"task\":\"ship-a\",\"seq\":9,\"verdict\":\"captain\",\"summary\":\"Passed to main directly (classifier): needs human\",\"wake\":\"heartbeat: single\"}\n",
   "ship-b.status":"## status lines appended since last outcome\n  (none)\n"},
  "args":{"wake":"heartbeat: single","seqs":["2"],"wakeKey":"wk-single","tasks":["ship-a"],"wakeNo":1,
          "evidence":[{"task":"ship-a","from":0,"to":99,
                       "text":"## status lines appended since last outcome\n  done: compiled the fleet chart\n## current state\nworking: implementing the fix\n\nSee https://github.com/acme/widgets/pull/9 for the review.\n"}]},
  "pane":[{"stdout":"noise\n{\"task\":\"ship-a\",\"tail\":\"last 40 lines of scrollback\",\"observation\":{\"mode\":\"implement\"},\"window\":\"w-77\",\"stale\":{\"series_index\":2,\"wedge_escalations\":1}}\n"}],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\",\"phase\":\"working\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\",\"phase\":\"working\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\",\"phase\":\"working\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\",\"phase\":\"working\"}}\n"}]},
 {"name":"control-wake10","config":"jev","files":{},
  "args":{"wake":"heartbeat: ten","seqs":["3"],"wakeKey":"wk-ten","tasks":["ship-a"],"wakeNo":10,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"}]},
 {"name":"stale-wake","config":"jev","files":{},
  "args":{"wake":"stale: ship-a stopped responding","seqs":["4"],"wakeKey":"wk-stale","tasks":["ship-a"],"wakeNo":2,
          "evidence":[{"task":"ship-a","from":0,"to":60,
                       "text":"## current state\nunknown: no readable state\n"}]},
  "pane":[{"stdout":"{\"unavailable\":\"no pane here\"}\n"}],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"main\",\"stale_state\":\"dead_or_unreadable\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"main\",\"stale_state\":\"dead_or_unreadable\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"main\",\"stale_state\":\"dead_or_unreadable\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"main\",\"stale_state\":\"dead_or_unreadable\"}}\n"}]},
 {"name":"compound","config":"jev","files":{},
  "args":{"wake":"heartbeat: two","seqs":["5","6"],"wakeKey":"wk-two","tasks":["ship-a","ship-b"],"wakeNo":3,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: a\n"},
                      {"task":"ship-b","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: b\n"}]},
  "pane":[],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"candidate:ship-a\":{\"type\":\"noul\",\"noul\":0.05},\"candidate:ship-b\":{\"type\":\"noul\",\"noul\":0.95}}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"candidate:ship-a\":{\"type\":\"noul\",\"noul\":0.9},\"candidate:ship-b\":{\"type\":\"noul\",\"noul\":0.2}}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"candidate:ship-a\":{\"type\":\"noul\",\"noul\":0.05},\"candidate:ship-b\":{\"type\":\"noul\",\"noul\":0.95}}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"candidate:ship-a\":{\"type\":\"noul\",\"noul\":0.05},\"candidate:ship-b\":{\"type\":\"noul\",\"noul\":0.95}}}\n"}]},
 {"name":"jev-unavailable","config":"jev","files":{},
  "args":{"wake":"heartbeat: sad","seqs":["7"],"wakeKey":"wk-sad","tasks":["ship-a"],"wakeNo":4,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],
  "jev":[{"stdout":"{\"ok\":false,\"unavailable\":\"model pool drained\"}\n"},
         {"stdout":"{\"ok\":false,\"unavailable\":\"model pool drained\"}\n"},
         {"stdout":"{\"ok\":false,\"unavailable\":\"model pool drained\"}\n"},
         {"stdout":"{\"ok\":false,\"unavailable\":\"model pool drained\"}\n"}]},
 {"name":"jev-no-json","config":"jev","files":{},
  "args":{"wake":"heartbeat: prose","seqs":["8"],"wakeKey":"wk-prose","tasks":["ship-a"],"wakeNo":5,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],
  "jev":[{"stdout":"plain text, no json at all\n"},
         {"stdout":"plain text, no json at all\n"},
         {"stdout":"plain text, no json at all\n"},
         {"stdout":"plain text, no json at all\n"}]},
 {"name":"jev-ok-no-noul","config":"jev","files":{},
  "args":{"wake":"heartbeat: flat","seqs":["9"],"wakeKey":"wk-flat","tasks":["ship-a"],"wakeNo":6,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"}]},
 {"name":"pane-throws","config":"jev","files":{},
  "args":{"wake":"heartbeat: no pane","seqs":["10"],"wakeKey":"wk-nopane","tasks":["ship-a"],"wakeNo":7,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[{"throw":"pane helper exploded"}],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"}]},
 {"name":"jev-throws","config":"jev","files":{},
  "args":{"wake":"heartbeat: jevdown","seqs":["15"],"wakeKey":"wk-jevdown","tasks":["ship-a"],"wakeNo":13,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],
  "jev":[{"throw":"jev exploded 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"},
         {"throw":"jev exploded 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"},
         {"throw":"jev exploded 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"},
         {"throw":"jev exploded 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"}]},
 {"name":"unread-multibyte","config":"jev",
  "files":{
   "ship-a.status":"## status lines appended since last outcome\n  done: compiled the fleet chart\n  done: compilation succeeded \u00e9\u00e8\n",
   ".ship-a.branch-outcome-index":"fm-branch-outcome-index-v1\t4\t77\tident\n"},
  "args":{"wake":"heartbeat: multibyte","seqs":["11"],"wakeKey":"wk-mb","tasks":["ship-a"],"wakeNo":8,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"}]},
 {"name":"request-bytes-multibyte","config":"jev","files":{},
  "args":{"wake":"heartbeat: bytes \u00e9\u00e8\u4e2d","seqs":["12"],"wakeKey":"wk-bytes","tasks":["ship-a"],"wakeNo":9,
          "evidence":[{"task":"ship-a","from":0,"to":30,"text":"## status lines appended since last outcome\n  done: caf\u00e9 r\u00e9sum\u00e9 \u4e2d\u6587\n"}]},
  "pane":[],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"}]},
 {"name":"shadow-log-error","config":"jev","files":{},"appendFail":true,
  "args":{"wake":"heartbeat: logdown","seqs":["13"],"wakeKey":"wk-logdown","tasks":["ship-a"],"wakeNo":11,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],
  "jev":[{"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"},
         {"stdout":"{\"ok\":true,\"model\":\"jev-7\",\"answers\":{\"route\":\"routine\"}}\n"}]},
 {"name":"shadow-error","config":"jev","files":{},"hasOpenThrow":true,
  "args":{"wake":"heartbeat: boom","seqs":["14"],"wakeKey":"wk-boom","tasks":["ship-a"],"wakeNo":12,
          "evidence":[{"task":"ship-a","from":0,"to":12,"text":"## status lines appended since last outcome\n  done: x\n"}]},
  "pane":[],
  "jev":[]}
]'

# ---------- lib driver -------------------------------------------------------
cat > "$TMP_ROOT/shadow-run.mjs" <<'DRIVER'
// Drives the shared lib module's runShadowAdvisory through the plan with an
// injected deterministic clock (iso "T", now() advancing 10 ms per call).
import { pathToFileURL } from "node:url";
const modulePath = process.argv[2];
const lib = await import(pathToFileURL(modulePath).href);
const plan = JSON.parse(process.argv[3]);
const STATE = "/fake/state";
const CONFIG = "/fake/config";
const out = [];
let nowMs = 0;
for (const step of plan) {
  const files = new Map(Object.entries(step.files ?? {}));
  const paneQueue = (step.pane ?? []).map((p) => p);
  const jevQueue = (step.jev ?? []).map((p) => p);
  const captures = { records: [], jev: [], pane: [], errors: [] };
  const deps = {
    paths: { bin: "/fake/bin", state: STATE },
    readFile: async (p) => {
      const key = String(p).startsWith(`${STATE}/`) ? String(p).slice(STATE.length + 1) : String(p);
      if (files.has(key)) return files.get(key);
      throw new Error("no file");
    },
    hasOpenCall: async (task) => {
      if (step.hasOpenThrow) throw new Error("open-call fold exploded");
      try {
        const text = await deps.readFile(`${STATE}/${task}.status`);
        return /\bneeds-decision\b/.test(text);
      } catch {
        return false;
      }
    },
    runScript: async (argv, opts) => {
      const script = String(argv[1] ?? "");
      if (script.endsWith("fm-branch-shadow-pane.sh")) {
        captures.pane.push({ task: argv[2], timeoutMs: opts.timeoutMs });
        const p = paneQueue.shift();
        if (p?.throw) throw new Error(p.throw);
        return { exitCode: 0, stdout: p?.stdout ?? "", stderr: "" };
      }
      if (script.endsWith("fm-branch-shadow-jev.sh")) {
        captures.jev.push({ stdin: opts.stdin ?? null, timeoutMs: opts.timeoutMs });
        const p = jevQueue.shift();
        if (p?.throw) throw new Error(p.throw);
        return { exitCode: 0, stdout: p?.stdout ?? "", stderr: "" };
      }
      return { exitCode: 0, stdout: "", stderr: "" };
    },
    readConfig: async (_name, fallback) => {
      const v = step.config;
      return v === undefined ? fallback : String(v).trim() || fallback;
    },
    appendShadowRecord: async (line) => {
      if (step.appendFail) throw new Error("shadow log down");
      captures.records.push(line);
    },
    onShadowError: (kind, error) => captures.errors.push({ kind, error: String(error) }),
    clock: { now: () => (nowMs += 10), iso: () => "T" },
  };
  await lib.runShadowAdvisory(deps, step.args);
  out.push({
    name: step.name,
    records: captures.records,
    jev: captures.jev,
    pane: captures.pane,
    errors: captures.errors,
  });
}
console.log(JSON.stringify(out));
DRIVER

# ---------- mod driver -------------------------------------------------------
cat > "$TMP_ROOT/mod-shadow-run.mjs" <<'DRIVER'
// Drives the REAL mod hook runShadowAdvisory through the same plan. The mod's
// clock and bind paths are host code: record t/ms are normalized and spawn
// paths projected to their script basenames before comparison.
import { pathToFileURL } from "node:url";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const root = process.env.FM_RS_ROOT;
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
const plan = JSON.parse(process.argv[2]);
const home = mkdtempSync(join(tmpdir(), "fm-shadow-mod-"));
process.env.FM_HOME = home;
const STATE = `${home}/state`;
const out = [];
const flush = () => new Promise((r) => setImmediate(r));
for (const step of plan) {
  const files = new Map(Object.entries(step.files ?? {}));
  const resolve = (p) => {
    if (p === `${home}/config/classifier-shadow` && step.config !== undefined) return String(step.config);
    for (const [rel, content] of files) {
      if (p === `${STATE}/${rel}` || p === `${home}/${rel}`) return content;
    }
    throw new Error("no file");
  };
  const paneQueue = (step.pane ?? []).map((p) => p);
  const jevQueue = (step.jev ?? []).map((p) => p);
  const captures = { records: [], jev: [], pane: [], errors: [] };
  let metaTask = null;
  const $ = {
    plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
    env: { get: async (name) => process.env[name] ?? "" },
    session: { cwd: async () => process.cwd() },
    fs: {
      exists: async () => false,
      read: async (p) => resolve(String(p)),
      write: async () => {},
      append: async () => {},
      mkdir: async () => {},
      rm: async () => {},
      readDir: async () => [],
      stat: async (p) => {
        metaTask = null;
        void p;
        return { isLink: false };
      },
    },
    ui: { log: () => {} },
    prompt: { submit: async () => {} },
    process: {
      run: async (argv, opts) => {
        if (argv[0] === "bash" && String(argv[1] ?? "").endsWith("fm-branch-shadow-pane.sh")) {
          captures.pane.push({ task: argv[2], timeoutMs: opts.timeoutMs });
          const p = paneQueue.shift();
          if (p?.throw) throw new Error(p.throw);
          return { exitCode: 0, stdout: p?.stdout ?? "", stderr: "" };
        }
        if (argv[0] === "bash" && String(argv[1] ?? "").endsWith("fm-branch-shadow-jev.sh")) {
          captures.jev.push({ stdin: opts.stdin ?? null, timeoutMs: opts.timeoutMs });
          const p = jevQueue.shift();
          if (p?.throw) throw new Error(p.throw);
          return { exitCode: 0, stdout: p?.stdout ?? "", stderr: "" };
        }
        if (argv[0] === "sh" && argv[1] === "-c") {
          const target = String(argv[4] ?? "");
          if (target.endsWith("branch-mod-shadow.jsonl")) {
            if (step.appendFail) throw new Error("shadow log down");
            captures.records.push(opts.stdin);
          } else if (target.endsWith("branch-mod-events.jsonl")) {
            const parsed = JSON.parse(opts.stdin);
            captures.errors.push({ kind: parsed.kind, error: parsed.data.error });
          }
          return { exitCode: 0, stdout: "", stderr: "" };
        }
        return { exitCode: 0, stdout: "", stderr: "" };
      },
    },
    model: { complete: async () => "" },
  };
  await mod.bind($, process.cwd());
  await mod.runShadowAdvisory($, step.args);
  await flush();
  await flush();
  out.push({
    name: step.name,
    records: captures.records,
    jev: captures.jev,
    pane: captures.pane,
    errors: captures.errors,
  });
  void metaTask;
}
console.log(JSON.stringify(out));
DRIVER

# ---------- run every leg ----------------------------------------------------
export FM_RS_ROOT="$ROOT"
echo "$PLAN" > "$TMP_ROOT/plan.json"
PLAN_ARG="$(cat "$TMP_ROOT/plan.json")"
node --experimental-strip-types "$TMP_ROOT/shadow-run.mjs" "$ROOT/lib/fm-branch-shadow.ts" "$PLAN_ARG" > "$TMP_ROOT/lib.json"
FM_RS_ROOT="$ROOT" node --experimental-strip-types "$TMP_ROOT/mod-shadow-run.mjs" "$PLAN_ARG" > "$TMP_ROOT/mod.json"
# A crashed driver writes an empty or partial file whose legs would then
# compare vacuously; require parseable non-empty output before comparing.
for leg in lib mod; do
  if [ ! -s "$TMP_ROOT/$leg.json" ] || ! jq -e 'type == "array" and length > 0' "$TMP_ROOT/$leg.json" > /dev/null; then
    fail "the $leg shadow driver produced no usable output"
  fi
done

# ---------- two-leg byte equality --------------------------------------------
# The mod leg must agree with the lib leg on every module-owned byte: the
# shadow records with the host clock normalized away, the jev request bodies,
# the pane helper spawns projected to task and timeout (the script's bind path
# is a host seam), and the error notifications. The shadow-error scenario is
# lib-only: the mod's hasOpenCall seam absorbs its own read failures, so the
# shared lib's never-throw catch is what the lib leg alone can demonstrate.
normalize_leg() {
  jq -S 'map(if .name == "shadow-error" then . + {libOnly: true, records: [], jev: [], pane: [], errors: []} else . end)
    | map(.records = (.records | map((. | fromjson) | .t = "T" | .ms = 0 | tostring)))
    | map(.pane = (.pane | map({task: .task, timeoutMs: .timeoutMs})))' "$1"
}
normalize_leg "$TMP_ROOT/lib.json" > "$TMP_ROOT/lib-norm.json"
normalize_leg "$TMP_ROOT/mod.json" > "$TMP_ROOT/mod-norm.json"
if cmp -s "$TMP_ROOT/lib-norm.json" "$TMP_ROOT/mod-norm.json"; then
  pass "the mod hook routes the shadow trial byte-identically to the shared module"
else
  fail "the mod hook's shadow output diverges from the shared module"
fi

# ---------- record shape, gate, and counts -----------------------------------
# Gate off: no records, no helper calls, no errors.
if [ "$(jq -r '.[0].records | length' "$TMP_ROOT/lib.json")" = "0" ] \
  && [ "$(jq -r '.[0].jev | length' "$TMP_ROOT/lib.json")" = "0" ] \
  && [ "$(jq -r '.[0].pane | length' "$TMP_ROOT/lib.json")" = "0" ] \
  && [ "$(jq -r '.[0].errors | length' "$TMP_ROOT/lib.json")" = "0" ]; then
  pass "a config other than jev keeps the whole shadow trial off"
else
  fail "the shadow gate did not stay off"
fi

# The record's pinned field order - the scorers parse this shape.
if [ "$(jq -r '.[1].records[0] | fromjson | keys_unsorted | join(",")' "$TMP_ROOT/lib.json")" \
  = "t,kind,wake,seqs,wakeKey,tasks,wakeNo,variant,repeat,control,unavailable,requestBytes,ms,policy,model,answers,facts" ]; then
  pass "shadow records keep their pinned field order"
else
  fail "the shadow record field order drifted"
fi

# Exactly one record per variant, in the pinned variant order.
if [ "$(jq -c '.[1].records | map(fromjson.variant)' "$TMP_ROOT/lib.json")" \
  = '["full","without_current_state","without_prior_outcomes","without_pane_tail"]' ] \
  && [ "$(jq -r '.[1].records | length' "$TMP_ROOT/lib.json")" = "4" ]; then
  pass "one record per ablation variant, in the pinned order"
else
  fail "the variant records drifted"
fi

# ---------- golden facts (the six-gate scorer's inputs) ----------------------
GOLDEN_FACTS='{"wake_key":"wk-single","new_status_bytes":{"ship-a":99},"authoritative_pr":{"present":true,"pr":"acme/widgets#9"},"severity_classes":["False alarm or no functional impact","Routine recoverable interruption or non-blocking failure","Task blocked or failed after normal recovery","Security, privacy, data-loss, irreversible, credential, or external-publication impact"],"pane":"w-77","stale_series":{"series_index":2,"wedge_escalations":1},"pane_observation":{"mode":"implement"}}'
if [ "$(jq -r '.[1].records[0] | fromjson | .facts | tostring' "$TMP_ROOT/lib.json")" = "$GOLDEN_FACTS" ]; then
  pass "shadow facts carry the byte-golden six-gate shape"
else
  fail "the shadow facts shape drifted"
fi

# The severity classes come from the question bundle, and the PR identity is
# folded from the evidence's pull-request URL.
if [ "$(jq -c '.[1].records[0] | fromjson | .facts.authoritative_pr' "$TMP_ROOT/lib.json")" \
  = '{"present":true,"pr":"acme/widgets#9"}' ]; then
  pass "authoritative PR facts fold the evidence's pull-request URL to its identity"
else
  fail "the authoritative PR fact drifted"
fi

# ---------- state assembly ---------------------------------------------------
# Unread status lines carry byte-range ids from the task's outcome endpoint.
if [ "$(jq -c '.[1].jev[0].stdin | fromjson | .state.unread_status | map(.id)' "$TMP_ROOT/lib.json")" \
  = '["ship-a:77-114"]' ]; then
  pass "unread status ids carry byte ranges from the outcome endpoint"
else
  fail "the unread status byte ids drifted"
fi

# Prior outcomes carry provenance: classifier passes vs accepted reports,
# same-wake identity, and presented state against the read cursor.
if [ "$(jq -c '.[1].jev[0].stdin | fromjson | .state.prior_outcomes | map({source, same_wake, already_presented, seq})' "$TMP_ROOT/lib.json")" \
  = '[{"source":"accepted_branch","same_wake":false,"already_presented":true,"seq":5},{"source":"classifier_pass","same_wake":true,"already_presented":false,"seq":9}]' ]; then
  pass "prior outcomes carry their provenance and read-cursor state"
else
  fail "the prior-outcome provenance drifted"
fi

# Fresh status lines are bounded to twelve per task.
if [ "$(jq -r '.[1].jev[0].stdin | fromjson | .state.fresh_status | length' "$TMP_ROOT/lib.json")" = "1" ]; then
  pass "fresh status lines ride the state at their bounded size"
else
  fail "the fresh status bounds drifted"
fi

# ---------- variants and the repeat control ----------------------------------
# Wake 10 gets the repeat control: five calls, the last a control repeat of
# the full bundle with the identical request body.
if [ "$(jq -r '.[2].jev | length' "$TMP_ROOT/lib.json")" = "5" ] \
  && [ "$(jq -r '.[2].records[4] | fromjson | .repeat' "$TMP_ROOT/lib.json")" = "2" ] \
  && [ "$(jq -r '.[2].records[4] | fromjson | .control' "$TMP_ROOT/lib.json")" = "true" ] \
  && [ "$(jq -r '.[2].records[4] | fromjson | .variant' "$TMP_ROOT/lib.json")" = "full" ] \
  && [ "$(jq -r '.[2].jev[4].stdin' "$TMP_ROOT/lib.json")" = "$(jq -r '.[2].jev[0].stdin' "$TMP_ROOT/lib.json")" ]; then
  pass "every tenth wake repeats the full variant as a control with an identical body"
else
  fail "the repeat control drifted"
fi

# Stale wakes add the stale_state question; the without_current_state variant
# drops current_state from the state while the full variant keeps it.
if [ "$(jq -r '.[3].jev[0].stdin | fromjson | .questions | has("stale_state")' "$TMP_ROOT/lib.json")" = "true" ] \
  && [ "$(jq -r '.[3].jev[0].stdin | fromjson | .state | has("current_state")' "$TMP_ROOT/lib.json")" = "true" ] \
  && [ "$(jq -r '.[3].jev[1].stdin | fromjson | .state | has("current_state")' "$TMP_ROOT/lib.json")" = "false" ]; then
  pass "stale wakes ask the stale_state question and ablate current_state per variant"
else
  fail "the stale-wake variants drifted"
fi

# A compound wake flattens each candidate into its own top-level typed
# question (a nested questions.candidates entry is rejected with HTTP 422),
# and each variant's record folds only its own flattened answers into facts.
if [ "$(jq -r '.[4].jev[0].stdin | fromjson | .questions | has("candidates")' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -c '.[4].jev[0].stdin | fromjson | .questions | keys | map(select(startswith("candidate:"))) | sort' "$TMP_ROOT/lib.json")" = '["candidate:ship-a","candidate:ship-b"]' ] \
  && [ "$(jq -r '.[4].jev[0].stdin | fromjson | [.questions[] | has("type")] | all' "$TMP_ROOT/lib.json")" = "true" ] \
  && [ "$(jq -c '.[4].records[0] | fromjson | .facts.candidates' "$TMP_ROOT/lib.json")" = '{"ship-a":0.05,"ship-b":0.95}' ] \
  && [ "$(jq -c '.[4].records[1] | fromjson | .facts.candidates' "$TMP_ROOT/lib.json")" = '{"ship-a":0.9,"ship-b":0.2}' ] \
  && [ "$(jq -r '.[4].records[0] | fromjson | .facts.wake_key' "$TMP_ROOT/lib.json")" = "wk-two" ]; then
  pass "compound wakes ask one top-level typed question per candidate and fold the flattened answers per variant"
else
  fail "the flattened compound request or its per-variant candidate fold drifted"
fi

# A single-task wake emits no candidate questions at all.
if [ "$(jq -r '.[1].jev[0].stdin | fromjson | .questions | has("candidates")' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[1].jev[0].stdin | fromjson | [.questions | keys[] | select(startswith("candidate:"))] | length' "$TMP_ROOT/lib.json")" = "0" ]; then
  pass "a single-task wake emits no candidate questions"
else
  fail "a single-task wake grew candidate questions"
fi

# The score script still prints one per-candidate row per compound record.
SCORE_CASE=$(fm_test_tmproot fm-branch-shadow-score-candidates)
jq -r '.[4].records[0]' "$TMP_ROOT/lib.json" > "$SCORE_CASE/shadow.jsonl"
: > "$SCORE_CASE/outcomes.jsonl"
SCORE_OUT=$(FM_STATE_OVERRIDE="$SCORE_CASE" "$ROOT/bin/fm-branch-shadow-score.sh" "$SCORE_CASE/shadow.jsonl" "$SCORE_CASE/outcomes.jsonl")
if printf '%s\n' "$SCORE_OUT" | grep -q 'candidates\.ship-a' \
  && printf '%s\n' "$SCORE_OUT" | grep -q 'candidates\.ship-b'; then
  pass "the score script still prints per-candidate rows for a compound record"
else
  fail "the score script lost the per-candidate rows: $SCORE_OUT"
fi

# The unavailable answers keep the record shaped: unavailable text, no model
# or answers fields, facts without candidates.
if [ "$(jq -r '.[5].records[0] | fromjson | .unavailable' "$TMP_ROOT/lib.json")" = "model pool drained" ] \
  && [ "$(jq -r '.[5].records[0] | fromjson | has("model")' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[5].records[0] | fromjson | has("answers")' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[5].records[0] | fromjson | .facts | has("candidates")' "$TMP_ROOT/lib.json")" = "false" ]; then
  pass "an unavailable jev answer records its reason without model or answers"
else
  fail "the unavailable-answer record drifted"
fi

# A jev stdout with no JSON line becomes the plain unavailable marker.
if [ "$(jq -r '.[6].records[0] | fromjson | .unavailable' "$TMP_ROOT/lib.json")" = "unavailable" ]; then
  pass "a jev stdout with no JSON line records the plain unavailable marker"
else
  fail "the no-JSON unavailable record drifted"
fi

# Answers without numeric candidate Nouls fold no candidates into facts.
if [ "$(jq -r '.[7].records[0] | fromjson | .model' "$TMP_ROOT/lib.json")" = "jev-7" ] \
  && [ "$(jq -r '.[7].records[0] | fromjson | .facts | has("candidates")' "$TMP_ROOT/lib.json")" = "false" ]; then
  pass "answers without numeric Nouls record the model but no candidates"
else
  fail "the no-noul record drifted"
fi

# ---------- pane and error surfaces ------------------------------------------
# An unavailable pane helper keeps pane fields out of the state and facts.
if [ "$(jq -r '.[3].jev[0].stdin | fromjson | .state | has("pane")' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[3].records[0] | fromjson | .facts | has("pane")' "$TMP_ROOT/lib.json")" = "false" ] \
  && [ "$(jq -r '.[3].records[0] | fromjson | .facts | has("stale_series")' "$TMP_ROOT/lib.json")" = "false" ]; then
  pass "an unavailable pane leaves pane fields absent from state and facts"
else
  fail "the pane-unavailable absence drifted"
fi

# A throwing pane helper is absorbed: no error surfaces, the trial continues.
if [ "$(jq -r '.[8].pane | length' "$TMP_ROOT/lib.json")" = "1" ] \
  && [ "$(jq -r '.[8].errors | length' "$TMP_ROOT/lib.json")" = "0" ] \
  && [ "$(jq -r '.[8].records | length' "$TMP_ROOT/lib.json")" = "4" ]; then
  pass "a throwing pane helper is absorbed without surfacing an error"
else
  fail "the pane-throw absorption drifted"
fi

# A throwing jev helper records the 200-capped helper-failure text.
JEV_FAIL_TEXT="helper failed: Error: jev exploded 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
if [ "$(jq -r '.[9].records[0] | fromjson | .unavailable' "$TMP_ROOT/lib.json")" = "${JEV_FAIL_TEXT:0:200}" ]; then
  pass "a throwing jev helper records its failure text capped at 200 characters"
else
  fail "the jev failure record drifted"
fi

# Multibyte unread ids: byte offsets count UTF-8 bytes, not characters.
if [ "$(jq -c '.[10].jev[0].stdin | fromjson | .state.unread_status | map(.id)' "$TMP_ROOT/lib.json")" \
  = '["ship-a:77-111"]' ]; then
  pass "multibyte unread ids carry UTF-8 byte offsets"
else
  fail "the multibyte unread ids drifted"
fi

# requestBytes counts UTF-8 bytes of the exact request body.
if [ "$(jq -r '.[11].records[0] | fromjson | .requestBytes' "$TMP_ROOT/lib.json")" \
  = "$(jq -r '.[11].jev[0].stdin | utf8bytelength' "$TMP_ROOT/lib.json")" ]; then
  pass "requestBytes equals the UTF-8 byte length of the request body"
else
  fail "the requestBytes measure drifted"
fi

# The jev request rides the pinned model name and the 10s helper timeout.
if [ "$(jq -r '.[1].jev[0].stdin | fromjson | .model' "$TMP_ROOT/lib.json")" = "jev-latest" ] \
  && [ "$(jq -r '.[1].jev[0].timeoutMs' "$TMP_ROOT/lib.json")" = "10000" ] \
  && [ "$(jq -r '.[1].pane[0].timeoutMs' "$TMP_ROOT/lib.json")" = "6000" ]; then
  pass "the jev request model and helper timeouts are byte-stable"
else
  fail "the helper request constants drifted"
fi

# ---------- error surface ----------------------------------------------------
# A failing shadow-log append notifies once per variant and writes no record.
if [ "$(jq -r '.[12].errors | map(.kind) | unique | join(",")' "$TMP_ROOT/lib.json")" = "shadow.log.error" ] \
  && [ "$(jq -r '.[12].errors | length' "$TMP_ROOT/lib.json")" = "4" ] \
  && [ "$(jq -r '.[12].records | length' "$TMP_ROOT/lib.json")" = "0" ] \
  && [ "$(jq -r '.[12].errors[0].error' "$TMP_ROOT/lib.json")" = "Error: shadow log down" ]; then
  pass "a failing shadow-log append notifies per variant without throwing"
else
  fail "the shadow-log error surface drifted"
fi

# The lib trial's own failure (here the open-call fold) becomes one
# shadow.error notification and no records; never a throw past the trial.
if [ "$(jq -r '.[13].errors | map(.kind) | join(",")' "$TMP_ROOT/lib.json")" = "shadow.error" ] \
  && [ "$(jq -r '.[13].records | length' "$TMP_ROOT/lib.json")" = "0" ]; then
  pass "a trial-level failure becomes one shadow.error notification"
else
  fail "the shadow.error surface drifted"
fi

# ---------- shim usage passthrough -------------------------------------------
# A fake curl stands in for the network: the shim must pass the response's
# usage object through unchanged, emit usage null when the response carries
# none, and print only the safe fields on one line - never the key.
SHIM_CASE=$(fm_test_tmproot fm-branch-shadow-jev-usage)
mkdir -p "$SHIM_CASE/fakebin" "$SHIM_CASE/home"
cat > "$SHIM_CASE/fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
_out=""
_wfmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) _out=$2; shift 2 ;;
    -w) _wfmt=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > /dev/null
cat "${FAKE_JEV_RESPONSE:?}" > "${_out:?}"
printf '%s\n' "${_wfmt//%\{http_code\}/200}"
SH
chmod +x "$SHIM_CASE/fakebin/curl"
printf '%s\n' 'TYPESAFE_API_KEY=sk-jev-trial-key' > "$SHIM_CASE/home/.env"
printf '%s' '{"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"main","confidence":0.91}},"usage":{"input_tokens":812,"output_tokens":60}}' > "$SHIM_CASE/response.json"
SHIM_OUT=$(PATH="$SHIM_CASE/fakebin:$PATH" FM_HOME="$SHIM_CASE/home" FAKE_JEV_RESPONSE="$SHIM_CASE/response.json" "$ROOT/bin/fm-branch-shadow-jev.sh" <<< '{"model":"jev-latest","state":{},"questions":{}}')
if [ "$(printf '%s\n' "$SHIM_OUT" | wc -l | tr -d ' ')" = "1" ] \
  && printf '%s' "$SHIM_OUT" | jq -e '.ok == true and .usage.input_tokens == 812 and .usage.output_tokens == 60' >/dev/null \
  && printf '%s' "$SHIM_OUT" | jq -e 'keys_unsorted == ["ok","model","answers","usage"]' >/dev/null \
  && ! printf '%s' "$SHIM_OUT" | grep -q 'sk-jev-trial-key'; then
  pass "the shim passes the response usage through on one safe line without the key"
else
  fail "the shim did not pass usage through cleanly: $SHIM_OUT"
fi

printf '%s' '{"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"main","confidence":0.91}}}' > "$SHIM_CASE/response.json"
SHIM_OUT=$(PATH="$SHIM_CASE/fakebin:$PATH" FM_HOME="$SHIM_CASE/home" FAKE_JEV_RESPONSE="$SHIM_CASE/response.json" "$ROOT/bin/fm-branch-shadow-jev.sh" <<< '{"model":"jev-latest","state":{},"questions":{}}')
if printf '%s' "$SHIM_OUT" | jq -e '.ok == true and .usage == null' >/dev/null; then
  pass "a response without usage records usage null rather than inventing one"
else
  fail "a usage-less response did not record usage null: $SHIM_OUT"
fi

# ---------- scorer cost section ----------------------------------------------
# A fixture log with metered and unmetered records across two wakes: the cost
# section prints exact per-variant totals with input median and nearest-rank
# latency p50/p95, plus one summed line per granted wake.
COST_CASE=$(fm_test_tmproot fm-branch-shadow-cost)
cat > "$COST_CASE/shadow.jsonl" <<'EOF'
{"t":"1","wake":"signal: A","seqs":["1"],"wakeKey":"wk-1","tasks":["t1"],"wakeNo":1,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":10,"policy":{},"answers":{"route":{"type":"choice","choice":"routine","confidence":0.9}},"usage":{"input_tokens":100,"output_tokens":10}}
{"t":"2","wake":"signal: A","seqs":["1"],"wakeKey":"wk-1","tasks":["t1"],"wakeNo":1,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":20,"policy":{},"answers":{"route":{"type":"choice","choice":"routine","confidence":0.9}},"usage":{"input_tokens":200,"output_tokens":20}}
{"t":"3","wake":"signal: A","seqs":["1"],"wakeKey":"wk-1","tasks":["t1"],"wakeNo":1,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":30,"policy":{},"answers":{"route":{"type":"choice","choice":"routine","confidence":0.9}}}
{"t":"4","wake":"signal: A","seqs":["1"],"wakeKey":"wk-1","tasks":["t1"],"wakeNo":1,"variant":"without_current_state","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":40,"policy":{},"answers":{"route":{"type":"choice","choice":"routine","confidence":0.9}},"usage":{"input_tokens":300,"output_tokens":30}}
{"t":"5","wake":"signal: A","seqs":["1"],"wakeKey":"wk-1","tasks":["t1"],"wakeNo":1,"variant":"without_current_state","repeat":1,"control":false,"unavailable":"http 503","requestBytes":10,"ms":50,"policy":{}}
{"t":"6","wake":"signal: B","seqs":["2"],"wakeKey":"wk-2","tasks":["t1"],"wakeNo":2,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{},"answers":{"route":{"type":"choice","choice":"routine","confidence":0.9}},"usage":{"input_tokens":50,"output_tokens":5}}
EOF
: > "$COST_CASE/outcomes.jsonl"
COST_OUT=$(FM_STATE_OVERRIDE="$COST_CASE" "$ROOT/bin/fm-branch-shadow-score.sh" "$COST_CASE/shadow.jsonl" "$COST_CASE/outcomes.jsonl")
if printf '%s\n' "$COST_OUT" | grep -q '^| full | 4 | 3 | 350 | 100 | 35 | 10 | 30 |$' \
  && printf '%s\n' "$COST_OUT" | grep -q '^| without_current_state | 2 | 1 | 300 | 300 | 30 | 40 | 50 |$' \
  && printf '%s\n' "$COST_OUT" | grep -q '^wake wk-1: input=600 output=60 records=5$' \
  && printf '%s\n' "$COST_OUT" | grep -q '^wake wk-2: input=50 output=5 records=1$'; then
  pass "the scorer's cost section prints exact per-variant totals with median and latency percentiles plus one summed line per granted wake"
else
  fail "the cost section drifted: $COST_OUT"
fi
