#!/usr/bin/env bash
# Tests for the shared spend-ledger producer bin/fm-spend-ledger-append.sh:
# every close path funnels through it, so a closure records its worker line no
# matter which path closed it.
#
# Covers the previously-skipped close paths and the ledger guarantees:
#   - a teardown that retains the captain's call stashes a spend context, and
#     the later answer-close appends the line after cleanup removed the record
#   - a failed spend query still appends an explicit unmeasured line
#   - a rerun appends no second line for the same closed task
#   - tasks that never ran a worker (other kinds, no record and no context)
#     record nothing, and a capture failure never fails the close.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPEND="$ROOT/bin/fm-spend-ledger-append.sh"
TMP_ROOT=$(fm_test_tmproot fm-spend-ledger-append)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# la_home <name>: a fixture home. Echoes the path.
la_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/home"
  printf '%s\n' "$home"
}

# la_meta <home> <task> [extra lines...]: a ship record with an epoch-shaped
# spawn generation and one activity sidecar, so the window is boundable.
la_meta() {
  local home=$1 task=$2
  shift 2
  {
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'harness=codex\n'
    printf 'model=default\n'
    printf 'effort=default\n'
    printf 'worktree=%s/wt\n' "$home"
    printf 'project=%s/project\n' "$home"
    printf 'branch=fm/%s\n' "$task"
    printf 'spawn_gen=s1700000000.123.abc\n'
    printf 'pr=https://github.com/example/repo/pull/7\n'
    printf '%s\n' "$@"
  } > "$home/state/$task.meta"
  : > "$home/state/$task.turn-ended"
}

# run_append <home> [args...]: the helper against the fixture home. NM_HOME
# points at the fixture unless the case seeds its own inventory, so no case
# reads the developer's real no-mistakes state for its pipeline columns.
run_append() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
    NM_HOME="${NM_HOME:-$home/nm-empty}" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    HOME="$home/home" \
    "$APPEND" "$@"
}

test_append_records_a_schema_two_line_with_pipeline_columns() {
  local home line
  home=$(la_home append-line)
  la_meta "$home" task-a1
  line=$(run_append "$home" task-a1) \
    || fail "the shared producer failed on a plain ship record"
  [ -n "$line" ] || fail "the shared producer printed no line"
  assert_equals '2' "$(jq -r .schema <<<"$line")" "the appended line is schema version 2"
  assert_equals 'task-a1' "$(jq -r .task <<<"$line")" "the line names the closed task"
  assert_equals 'pr' "$(jq -r .outcome <<<"$line")" "the line derives the PR outcome from the record"
  assert_equals 'https://github.com/example/repo/pull/7' "$(jq -r .outcome_ref <<<"$line")" "the line carries the PR URL"
  [ -n "$(jq -r .ts <<<"$line")" ] || fail "the line carries no timestamp"
  jq -e '.pipeline_runs == 0 and .pipeline_invocations == 0 and .pipeline_usd == null' <<<"$line" >/dev/null \
    || fail "a branch no inventory resolves zeroes the pipeline counts: $line"
  assert_equals 'unmeasured' "$(jq -r .pipeline_cost_lane <<<"$line")" "an unresolvable pipeline scope stays unmeasured"
  [ -n "$(jq -r .pipeline_note <<<"$line")" ] \
    || fail "an unmeasured pipeline must state its reason"
  assert_equals '1' "$(wc -l < "$home/data/spend-ledger.jsonl")" "one close appends exactly one line"
  # A rerun prints the recorded line and appends nothing.
  line=$(run_append "$home" task-a1) \
    || fail "a rerun append failed"
  assert_equals '1' "$(wc -l < "$home/data/spend-ledger.jsonl")" "a rerun appends no second line"
  assert_equals 'task-a1' "$(jq -r .task <<<"$line")" "a rerun prints the recorded line"
  pass "one close appends exactly one schema-versioned line with pipeline columns"
}

test_retain_stash_then_answer_append_records_the_line() {
  local home line end_epoch
  home=$(la_home retain-stash)
  la_meta "$home" task-r1 harness=claude
  run_append "$home" --stash task-r1 >/dev/null \
    || fail "stashing the spend context failed"
  [ -f "$home/state/task-r1.spend-context" ] \
    || fail "a retain records no spend context for the later close"
  [ ! -e "$home/data/spend-ledger.jsonl" ] \
    || fail "stashing must not append a ledger line for a still-open call"
  assert_equals 'ship' "$(sed -n 's/^kind=//p' "$home/state/task-r1.spend-context")" "the context proves a worker task"
  assert_equals 'pr' "$(sed -n 's/^outcome=//p' "$home/state/task-r1.spend-context")" "the context freezes the outcome"
  end_epoch=$(sed -n 's/^end_epoch=//p' "$home/state/task-r1.spend-context")
  [ -n "$end_epoch" ] || fail "the context freezes the window end"
  # Cleanup removes the record and sidecars; the answer-close appends from
  # the context alone.
  rm -f -- "$home/state/task-r1.meta" "$home/state/task-r1.turn-ended"
  line=$(run_append "$home" task-r1) \
    || fail "the answer-close append failed without a record"
  [ -n "$line" ] || fail "the answer-close printed no line"
  assert_equals 'task-r1' "$(jq -r .task <<<"$line")" "the answered line names the closed task"
  assert_equals 'pr' "$(jq -r .outcome <<<"$line")" "the answered line keeps the stashed outcome"
  assert_equals 'https://github.com/example/repo/pull/7' "$(jq -r .outcome_ref <<<"$line")" "the answered line keeps the stashed PR URL"
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$line")" "without session logs the worker figure is unmeasured"
  assert_equals '1700000000' "$(jq -r .window.start_epoch <<<"$line")" "the stashed spawn epoch bounds the window"
  assert_equals "$end_epoch" "$(jq -r .window.end_epoch <<<"$line")" "the stashed sidecar bound ends the window"
  [ ! -e "$home/state/task-r1.spend-context" ] \
    || fail "a successful append removes the spent context"
  assert_equals '1' "$(wc -l < "$home/data/spend-ledger.jsonl")" "the answer closes with exactly one line"
  pass "a task closed by a captain answer after cleanup still records its line"
}

test_failed_query_still_appends_an_unmeasured_line() {
  local home broken_bin line
  home=$(la_home broken-query)
  la_meta "$home" task-b1
  # A python3 stub that is found but fails: the query and the pipeline read
  # both fall over, so every fallback fires and the line must still land.
  broken_bin="$home/broken-bin"
  mkdir -p "$broken_bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$broken_bin/python3"
  chmod +x "$broken_bin/python3"
  line=$(PATH="$broken_bin:$PATH" run_append "$home" task-b1) \
    || fail "the producer failed when the spend query broke"
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$line")" "the fallback line is unmeasured"
  assert_contains "$(jq -r .unmeasured_reason <<<"$line")" "spend query failed" "the fallback names the failed capture"
  assert_equals 'unmeasured' "$(jq -r .pipeline_cost_lane <<<"$line")" "the fallback pipeline is unmeasured"
  assert_equals '1' "$(wc -l < "$home/data/spend-ledger.jsonl")" "a failed query still leaves exactly one line"
  pass "a failed spend query records an explicit unmeasured line instead of none"
}

test_capture_failure_never_fails_the_close() {
  local home shadow_bin err rc
  home=$(la_home unwritable)
  la_meta "$home" task-u1
  # A jq stub that always fails: no line can be built or merged.
  shadow_bin="$home/shadow-bin"
  mkdir -p "$shadow_bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$shadow_bin/jq"
  chmod +x "$shadow_bin/jq"
  err=$(PATH="$shadow_bin:$PATH" run_append "$home" task-u1 2>&1)
  rc=$?
  expect_code 0 "$rc" "a capture failure must never fail the close"
  [ -n "$err" ] || fail "a capture failure must say so on stderr"
  [ ! -e "$home/data/spend-ledger.jsonl" ] \
    || fail "an unbuildable line must not be half-appended"
  pass "a capture failure stays best effort and wakes nobody"
}

test_tasks_without_a_worker_record_nothing() {
  local home out
  home=$(la_home no-worker)
  la_meta "$home" task-s1 "kind=secondmate"
  sed -i 's/^kind=ship$/kind=secondmate/' "$home/state/task-s1.meta"
  out=$(run_append "$home" task-s1) \
    || fail "the producer failed on a non-worker task"
  [ -z "$out" ] || fail "a secondmate retirement must record no spend line"
  [ ! -e "$home/data/spend-ledger.jsonl" ] \
    || fail "a secondmate retirement must leave the ledger alone"
  out=$(run_append "$home" task-ghost) \
    || fail "the producer failed on an unknown task"
  [ -z "$out" ] || fail "a task with no record and no context must record nothing"
  pass "tasks that never ran a worker record no spend line"
}

# la_nm_seed <home> [repo-path]: a no-mistakes inventory with one priced run on
# fm/task-p1, keyed by <repo-path> (default the fixture's project clone).
la_nm_seed() {
  local home=$1 nm="$1/nm"
  mkdir -p "$nm"
  NM_SEED="$nm/state.sqlite" NM_REPO_PATH="${2:-$home/project}" python3 - <<'PY'
import os
import sqlite3
path = os.environ["NM_SEED"]
db = sqlite3.connect(path)
db.execute("CREATE TABLE repos(id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE)")
db.execute("CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, created_at INTEGER NOT NULL)")
db.execute("CREATE TABLE agent_invocations(id TEXT PRIMARY KEY, run_id TEXT NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, duration_ms INTEGER)")
db.execute("INSERT INTO repos VALUES('r1',?)", (os.environ["NM_REPO_PATH"],))
db.execute("INSERT INTO runs VALUES('run1','r1','fm/task-p1',1)")
db.execute("INSERT INTO agent_invocations VALUES('i1','run1','claude-sonnet-4-1',2000,400,4000,50,45000)")
db.commit()
db.close()
PY
  printf '%s\n' "$nm"
}

test_append_records_pipeline_runs_for_the_task_branch() {
  local home nm line
  home=$(la_home pipeline-branch)
  la_meta "$home" task-p1
  nm=$(la_nm_seed "$home")
  line=$(NM_HOME="$nm" run_append "$home" task-p1) \
    || fail "the producer failed with pipeline runs present"
  assert_equals '1' "$(jq -r .pipeline_runs <<<"$line")" "the task branch's run is counted"
  assert_equals '1' "$(jq -r .pipeline_invocations <<<"$line")" "the run's invocation is counted"
  assert_equals '2000' "$(jq -r .pipeline_input_tokens <<<"$line")" "the run's input tokens are summed"
  assert_equals '45000' "$(jq -r .pipeline_agent_ms <<<"$line")" "the run's agent duration is summed"
  assert_equals 'api-equiv' "$(jq -r .pipeline_cost_lane <<<"$line")" "a fully priced pipeline reads api-equiv"
  jq -e '.pipeline_usd > 0' <<<"$line" >/dev/null \
    || fail "the priced pipeline carries no cost: $line"
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$line")" "the uncovered harness leaves the worker figure unmeasured"
  jq -e 'has("pipeline_note") | not' <<<"$line" >/dev/null \
    || fail "a priced pipeline line must carry no pipeline note: $line"
  pass "the ledger line carries the task branch's pipeline cost"
}

test_append_records_pipeline_runs_keyed_by_the_task_worktree() {
  local home nm line
  home=$(la_home pipeline-worktree)
  la_meta "$home" task-p1
  # The pipeline ran from inside the task's own pooled worktree, so the
  # inventory keys its repo by that path and not by the project clone.
  nm=$(la_nm_seed "$home" "$home/wt/projects/sample")
  line=$(NM_HOME="$nm" run_append "$home" task-p1) \
    || fail "the producer failed with worktree-keyed pipeline runs present"
  assert_equals '1' "$(jq -r .pipeline_runs <<<"$line")" "a run keyed by the task worktree is counted"
  assert_equals 'api-equiv' "$(jq -r .pipeline_cost_lane <<<"$line")" "the worktree-keyed run is priced, not zeroed"
  jq -e '.pipeline_usd > 0' <<<"$line" >/dev/null \
    || fail "the worktree-keyed pipeline carries no cost: $line"
  pass "a pipeline run recorded against the task worktree lands on the task's line"
}

test_append_records_a_schema_two_line_with_pipeline_columns
test_retain_stash_then_answer_append_records_the_line
test_failed_query_still_appends_an_unmeasured_line
test_capture_failure_never_fails_the_close
test_tasks_without_a_worker_record_nothing
test_append_records_pipeline_runs_for_the_task_branch
test_append_records_pipeline_runs_keyed_by_the_task_worktree

echo "OK: fm-spend-ledger-append"
