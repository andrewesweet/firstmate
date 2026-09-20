#!/usr/bin/env bash
# Portable three-fold equivalence proof for the wake-eligibility and
# open-decision classification (the "branch fold"), which exists twice in
# TypeScript plus once in bash:
#   - bin/fm-classify-lib.sh `status_open_decisions` (the authoritative v8
#     fold: needs-decision/blocked open a keyed decision, resolved/captain-held
#     close one, and a done:/failed: declaration clears the whole set when the
#     task's kind is ship or scout);
#   - the Pi extension's exported `scopeForUnreadWake`
#     (.pi/extensions/lib/fm-branch-dispatch.ts);
#   - the Claude mod's exported `scopeForUnreadWake`
#     (.claude/mods/fm-branch-mod/hooks/branch.ts), bound through its exported
#     `bind` - both exports are behavior-neutral (decision
#     a0-mod-fold-export, option b) and exist so this test can drive the real
#     implementation instead of a re-implementation.
# One fixture set (status logs, wake-queue rows, task metas) is driven through
# all three, and the two TypeScript legs must emit byte-identical normalised
# scope JSON wherever the folds agree. Bash contributes the fold truth alone:
# no bash-side eligible-row scan exists (the extension computes the eligible
# snapshot and bin/fm-wake-drain.sh consumes it), so the bash leg pins
# `status_open_decisions` output and the join between fold truth and scope.
# Today's known drift is asserted as documented drift with a pointer at the
# stage-A2 shared fold module, not as agreement:
#   - v8 drift: Pi lacks the terminal-close rule, so a ship task's open
#     needs-decision followed by done: stays decision-owned there while bash
#     and the mod clear it;
#   - symlink drift: Pi refuses a symlinked status log for the whole scan
#     while bash's refusal names an empty fold (branch-eligible) and the mod
#     reads through the link;
#   - torn-epoch drift: the mod validates the epoch field digit-wise and
#     refuses the scan; Pi validates only the seq and claims the row.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-eligibility)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the branch-eligibility equivalence checks"; exit 0; }

# Pin the fold vocabulary and home overrides: an ambient FM_CLASSIFY_* export
# or home override would decide the verdicts this equivalence compares, so
# every leg runs with them cleared and the documented defaults in force.
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_CLASSIFY_RESOLVE_VERB FM_CLASSIFY_CAPTAIN_HELD_VERB FM_CLASSIFY_RESERVED_KEY_PREFIXES

build_fixtures() {
  local fx="$TMP_ROOT/fx"
  # Plain routine signal row for a working ship task.
  mkdir -p "$fx/routine"
  printf 'working: implementing the fix\n' >"$fx/routine/ship-a.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/routine/ship-a.meta"
  printf '1\t1\tsignal\tship-a.status\tsignal: working\n' >"$fx/routine/.wake-queue"
  # The v8 row: open needs-decision then a done: declaration (terminal close).
  mkdir -p "$fx/v8-ship"
  printf 'needs-decision [key=dep]: waiting on captain\ndone: PR https://example.com/pr/1 checks green\n' >"$fx/v8-ship/ship-b.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/v8-ship/ship-b.meta"
  printf '2\t2\tstale\tship-b\tstale: waiting too long\n' >"$fx/v8-ship/.wake-queue"
  # Scout terminal: open blocked then failed: (terminal close covers scout).
  mkdir -p "$fx/scout-terminal"
  printf 'blocked [key=deps]: upstream broke the API\nfailed: reproduced and reported upstream\n' >"$fx/scout-terminal/scout-c.status"
  printf 'kind=scout\nproject=demo\n' >"$fx/scout-terminal/scout-c.meta"
  printf '3\t3\tstale\tscout-c\tstale: waiting too long\n' >"$fx/scout-terminal/.wake-queue"
  # Symlinked status log over a plain resolved log (bash truth: refusal means
  # an empty fold, so the stale row stays branch-eligible).
  mkdir -p "$fx/symlink-log"
  printf 'working: on it\n' >"$fx/symlink-log/ship-d-real.status"
  ln -s ship-d-real.status "$fx/symlink-log/ship-d.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/symlink-log/ship-d.meta"
  printf '4\t4\tstale\tship-d\tstale: waiting too long\n' >"$fx/symlink-log/.wake-queue"
  # Torn epoch field in the queue row (non-numeric epoch, valid seq).
  mkdir -p "$fx/torn-epoch"
  printf 'working: on it\n' >"$fx/torn-epoch/ship-e.status"
  printf 'kind=ship\nproject=demo\n' >"$fx/torn-epoch/ship-e.meta"
  printf 'torn\t5\tsignal\tship-e.status\tsignal: working\n' >"$fx/torn-epoch/.wake-queue"
  # Secondmate control: a secondmate's done: never clears an open decision.
  mkdir -p "$fx/secondmate-held"
  printf 'needs-decision [key=gate]: captain pick\ndone: unrelated cleanup finished\n' >"$fx/secondmate-held/mate-f.status"
  printf 'kind=secondmate\nproject=demo\n' >"$fx/secondmate-held/mate-f.meta"
  printf '6\t6\tstale\tmate-f\tstale: waiting too long\n' >"$fx/secondmate-held/.wake-queue"
  printf '%s\n' "$fx"
}

FIXTURES=$(build_fixtures)

# The Pi leg: import the real extension module and classify the fixture state.
pi_scope() { # <state-dir> -> normalised scope JSON
  FM_ELIGIBILITY_ROOT="$ROOT" node "$TMP_ROOT/pi-scope.mjs" "$1"
}

# The mod leg: import the real hooks module, bind its module state to the
# fixture state through the exported bind, then classify.
mod_scope() { # <state-dir> -> normalised scope JSON
  FM_ELIGIBILITY_ROOT="$ROOT" FM_STATE_OVERRIDE="$1" node "$TMP_ROOT/mod-scope.mjs"
}

# The bash leg: the authoritative fold through its public entry point, with
# the kind resolved from the task's meta exactly as production resolves it.
bash_fold() { # <state-dir> <task> -> v8 open set, or empty
  bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2/$3.status"' _ "$ROOT" "$1" "$2"
}

write_runners() {
  # Normalised scope shape shared by both TS legs: the mod Scope carries
  # eligibleWakeKey/allSeqs and the Pi scope carries projects/checkSeqs/
  # heartbeatSeqs/taskByWakeKey, which have no counterpart on the other side;
  # the compared fields are the ones both expose with the same meaning.
  cat >"$TMP_ROOT/pi-scope.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const root = process.env.FM_ELIGIBILITY_ROOT;
if (!root) throw new Error("FM_ELIGIBILITY_ROOT required");
const { scopeForUnreadWake } = await import(pathToFileURL(`${root}/.pi/extensions/lib/fm-branch-dispatch.ts`).href);
const norm = (s) => JSON.stringify({
  status: s.status,
  eligible: s.eligible,
  corrupted: s.corrupted,
  eligibleSeqs: [...new Set(s.eligibleSeqs)].sort(),
  eligibleTasks: [...new Set(s.eligibleTasks)].sort(),
  needsDecision: [...new Set(s.needsDecisionKeys)].sort(),
});
for (const dir of process.argv.slice(2)) {
  process.stdout.write(`${norm(scopeForUnreadWake(dir, false, false))}\n`);
}
JS
  cat >"$TMP_ROOT/mod-scope.mjs" <<'JS'
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";
const root = process.env.FM_ELIGIBILITY_ROOT;
if (!root) throw new Error("FM_ELIGIBILITY_ROOT required");
const stateDir = process.env.FM_STATE_OVERRIDE;
if (!stateDir) throw new Error("FM_STATE_OVERRIDE required");
const mod = await import(pathToFileURL(`${root}/.claude/mods/fm-branch-mod/hooks/branch.ts`).href);
// The host seam the fold reads through, backed by node:fs with its documented
// read/list/exists behavior; the fs methods are awaited exactly as the mod
// awaits the host they stand in for.
const $ = {
  plugin: { root: `${root}/.claude/mods/fm-branch-mod` },
  session: { cwd: async () => process.cwd() },
  env: { get: async (name) => process.env[name] ?? "" },
  fs: {
    read: async (path) => {
      if (!existsSync(path)) throw new Error(`ENOENT: ${path}`);
      return readFileSync(path, "utf8");
    },
    list: async (dir) => readdirSync(dir, { withFileTypes: true }),
    exists: async (path) => existsSync(path),
  },
};
if (typeof mod.bind !== "function") throw new Error("branch.ts does not export bind");
if (typeof mod.scopeForUnreadWake !== "function") throw new Error("branch.ts does not export scopeForUnreadWake");
await mod.bind($, process.cwd());
const norm = (s) => JSON.stringify({
  status: s.status,
  eligible: s.eligible,
  corrupted: s.corrupted,
  eligibleSeqs: [...new Set(s.eligibleSeqs)].sort(),
  eligibleTasks: [...new Set(s.eligibleTasks)].sort(),
  needsDecision: [...new Set(s.needsDecisionTasks)].sort(),
});
process.stdout.write(`${norm(await mod.scopeForUnreadWake($, false))}\n`);
JS
}

write_runners

test_routine_signal_row_agrees_across_all_three_folds() {
  local dir="$FIXTURES/routine" pi mod fold
  pi=$(pi_scope "$dir") || fail "routine: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "routine: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "ship-a")
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["1"],"eligibleTasks":["ship-a"],"needsDecision":[]}' "$pi" "routine: pi scope"
  assert_equals "$pi" "$mod" "routine: pi and mod scopes must be byte-identical"
  assert_equals "" "$fold" "routine: bash fold must be empty (nothing holds ship-a)"
  pass "a plain routine signal row classifies identically in bash, the Pi extension, and the mod"
}

test_ship_terminal_declaration_is_the_documented_v8_drift() {
  # Bash truth: done: on a ship task clears the whole open set, so nothing
  # holds ship-b and its stale row stays branch-eligible. The mod agrees; Pi
  # lacks the terminal-close rule and keeps the row decision-owned. Stage A2's
  # shared fold module retires this drift assertion.
  local dir="$FIXTURES/v8-ship" pi mod fold
  pi=$(pi_scope "$dir") || fail "v8: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "v8: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "ship-b")
  assert_equals "" "$fold" "v8: bash truth - the terminal done: must empty the fold for a ship task"
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["2"],"eligibleTasks":["ship-b"],"needsDecision":[]}' "$mod" "v8: mod agrees with bash truth (terminal close, row branch-eligible)"
  assert_equals '{"status":"unsafe","eligible":false,"corrupted":false,"eligibleSeqs":[],"eligibleTasks":[],"needsDecision":["ship-b"]}' "$pi" "v8: documented drift - pi keeps the done: task decision-owned"
  assert_not_equals "$pi" "$mod" "v8: the drift must remain visible until stage A2 aligns the folds"
  pass "the v8 drift (pi missing the terminal-close rule) is asserted as documented drift against bash truth and the mod"
}

test_scout_blocked_then_failed_agrees_across_all_three_folds() {
  # Bash truth: failed: on a scout task clears the open blocked key, so the
  # stale row stays branch-eligible. Pi's internal open map keeps the blocked
  # key (it has no terminal close), but its needs-decision-specific verdict
  # and the mod's cleared set produce the same scope: byte-identical output.
  local dir="$FIXTURES/scout-terminal" pi mod fold
  pi=$(pi_scope "$dir") || fail "scout: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "scout: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "scout-c")
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["3"],"eligibleTasks":["scout-c"],"needsDecision":[]}' "$pi" "scout: pi scope"
  assert_equals "$pi" "$mod" "scout: pi and mod scopes must be byte-identical"
  assert_equals "" "$fold" "scout: bash truth - the terminal failed: must empty the fold for a scout task"
  pass "a scout task with open blocked then failed: classifies identically in bash, the Pi extension, and the mod"
}

test_symlinked_status_log_names_bash_truth_and_the_pi_drift() {
  # Bash truth: status_open_decisions refuses a symlinked status log outright,
  # which names an empty fold - nothing holds ship-d and its stale row stays
  # branch-eligible. The mod reads through the link and agrees. Pi's
  # statusFileVersion refuses the symlink for the whole scan (unsafe). Stage
  # A2's shared fold module retires this drift assertion.
  local dir="$FIXTURES/symlink-log" pi mod fold
  pi=$(pi_scope "$dir") || fail "symlink: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "symlink: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "ship-d")
  assert_equals "" "$fold" "symlink: bash truth - the refusal must name an empty fold"
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["4"],"eligibleTasks":["ship-d"],"needsDecision":[]}' "$mod" "symlink: mod reads through the link and agrees with bash truth"
  assert_equals '{"status":"unsafe","eligible":false,"corrupted":true,"eligibleSeqs":[],"eligibleTasks":[],"needsDecision":[]}' "$pi" "symlink: documented drift - pi refuses the whole scan"
  assert_not_equals "$pi" "$mod" "symlink: the drift must remain visible until stage A2 aligns the folds"
  pass "the symlink refusal names bash truth (branch-eligible) and pi's whole-scan refusal is asserted as documented drift"
}

test_torn_epoch_row_is_the_documented_epoch_validation_drift() {
  # The mod validates the epoch field digit-wise and refuses the scan; Pi
  # validates only the seq and claims the row. Bash has no queue scan to
  # contribute; its fold on the task's own log names the empty truth. Stage
  # A1's shared module adds epoch+seq validation on both sides.
  local dir="$FIXTURES/torn-epoch" pi mod fold
  pi=$(pi_scope "$dir") || fail "epoch: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "epoch: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "ship-e")
  assert_equals "" "$fold" "epoch: the task's own log holds no decision"
  assert_equals '{"status":"safe","eligible":true,"corrupted":false,"eligibleSeqs":["5"],"eligibleTasks":["ship-e"],"needsDecision":[]}' "$pi" "epoch: documented drift - pi claims the torn-epoch row"
  assert_equals '{"status":"unsafe","eligible":false,"corrupted":true,"eligibleSeqs":[],"eligibleTasks":[],"needsDecision":[]}' "$mod" "epoch: the mod refuses the scan on the non-numeric epoch"
  assert_not_equals "$pi" "$mod" "epoch: the drift must remain visible until stage A1 aligns the validation"
  pass "the torn-epoch queue row is asserted as documented drift (mod validates the epoch, pi does not)"
}

test_secondmate_terminal_declaration_does_not_close_the_decision_anywhere() {
  # A secondmate's done: may describe unrelated work, so no fold clears an
  # open decision on it: bash keeps the key, the mod skips the clear for a
  # secondmate kind, and pi never clears. All three must agree the row is
  # decision-owned and the scope is main-owned (unsafe, nothing eligible).
  local dir="$FIXTURES/secondmate-held" pi mod fold
  pi=$(pi_scope "$dir") || fail "secondmate: pi leg failed: $pi"
  mod=$(mod_scope "$dir") || fail "secondmate: mod leg failed: $mod"
  fold=$(bash_fold "$dir" "mate-f")
  assert_equals "$(printf 'gate\tneeds-decision\tcaptain pick')" "$fold" "secondmate: bash keeps the open key across the terminal line"
  assert_equals '{"status":"unsafe","eligible":false,"corrupted":false,"eligibleSeqs":[],"eligibleTasks":[],"needsDecision":["mate-f"]}' "$pi" "secondmate: pi scope"
  assert_equals "$pi" "$mod" "secondmate: pi and mod scopes must be byte-identical"
  pass "a secondmate's terminal declaration holds the open decision in bash, the Pi extension, and the mod alike"
}

test_routine_signal_row_agrees_across_all_three_folds
test_ship_terminal_declaration_is_the_documented_v8_drift
test_scout_blocked_then_failed_agrees_across_all_three_folds
test_symlinked_status_log_names_bash_truth_and_the_pi_drift
test_torn_epoch_row_is_the_documented_epoch_validation_drift
test_secondmate_terminal_declaration_does_not_close_the_decision_anywhere
