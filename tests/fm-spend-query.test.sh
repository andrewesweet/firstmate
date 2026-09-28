#!/usr/bin/env bash
# Tests for the per-task spend capture: bin/fm-spend-query.sh's record
# resolution (env overrides, the spawn-epoch-to-activity-sidecar window,
# malformed id and missing record refusals, the python3-absent unmeasured
# fallback) and
# bin/fm-spend-query.py's measurement (Claude api-equiv pricing with
# message-id dedupe and mandatory window bounding, Pi recorded costs, explicit
# unmeasured reasons for uncovered runtimes and missing logs, and
# bin/fm-brief-composition.py's scaffold-versus-task split).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUERY="$ROOT/bin/fm-spend-query.sh"
PARSER="$ROOT/bin/fm-spend-query.py"
COMPOSITION="$ROOT/bin/fm-brief-composition.py"

TMP_ROOT=$(fm_test_tmproot fm-spend-query)

# sq_home <name>: a fixture home whose HOME tree carries session-log dirs.
sq_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/home"
  printf '%s\n' "$home"
}

# sq_meta <home> <task> <body lines...>: write a task record.
sq_meta() {
  local home=$1 task=$2
  shift 2
  {
    printf 'kind=ship\n'
    printf 'harness=claude\n'
    printf 'model=claude-opus-4-1\n'
    printf 'effort=xhigh\n'
    printf 'worktree=%s/wt\n' "$home"
    printf 'spawn_gen=s1700000000.123.abc\n'
    printf '%s\n' "$@"
  } > "$home/state/$task.meta"
  # The window's end bound is the newest mtime among the task's own activity
  # sidecars, so a fixture record needs one to be measurable at all.
  : > "$home/state/$task.turn-ended"
}

sq_claude_dir() {  # <home> <worktree>
  local munged
  munged=$(printf '%s' "$2" | sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "$1/home/.claude/projects/$munged"
  printf '%s\n' "$1/home/.claude/projects/$munged"
}

sq_pi_dir() {  # <home> <worktree>
  local stripped munged
  stripped=${2#/}
  munged="--${stripped//\//-}--"
  mkdir -p "$1/home/.pi/agent/sessions/$munged"
  printf '%s\n' "$1/home/.pi/agent/sessions/$munged"
}

sq_query() {  # <home> <task>
  HOME="$1/home" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    "$QUERY" "$2"
}

sq_json() {  # <home> <task> <jq filter>
  sq_query "$1" "$2" | jq -r "$3"
}

# --- Claude measurement: dedupe, window bounding, api-equiv pricing ----------

# --- Pipeline columns ----------------------------------------------------------

# Seed a minimal no-mistakes inventory through python's own sqlite3, so the
# fixture needs no sqlite3 CLI: only the columns the collector reads.
sp_nm_seed() {  # <nm-home>; prints the path
  local nm=$1
  mkdir -p "$nm"
  NM_SEED="$nm/state.sqlite" python3 - <<'PY'
import os
import sqlite3
path = os.environ["NM_SEED"]
db = sqlite3.connect(path)
db.execute("CREATE TABLE repos(id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE)")
db.execute("CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, created_at INTEGER NOT NULL)")
db.execute("CREATE TABLE agent_invocations(id TEXT PRIMARY KEY, run_id TEXT NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, duration_ms INTEGER, exit_status TEXT)")
db.execute("INSERT INTO repos VALUES('r1','/pipe-proj')")
db.execute("INSERT INTO runs VALUES('runA','r1','fm/pipe1',1),('runB','r1','fm/pipe1',2),('runC','r1','fm/other',3)")
db.execute("INSERT INTO agent_invocations VALUES" +
           "('a1','runA','claude-opus-4-1',1000,500,9000,100,60000,'completed')," +
           "('a2','runA','gpt-mystery',2000,1000,0,0,30000,'completed')," +
           "('a3','runA',NULL,NULL,NULL,NULL,NULL,7000,'completed')," +
           "('a4','runA','claude-opus-4-1',4000,2000,0,0,5000,'cancelled')," +
           "('a5','runB','gpt-broken',1234,0,0,0,7000,'error')," +
           "('b1','runB','claude-opus-4-1',500,100,100,10,10000,'completed')," +
           "('c1','runC','claude-opus-4-1',999999,999999,999999,999999,999999,'completed')")
db.commit()
db.close()
PY
  printf '%s\n' "$nm"
}

test_pipeline_counts_measured_and_null_token_invocations() {
  local nm out
  nm=$(sp_nm_seed "$TMP_ROOT/nm-pipeline-mixed")
  out=$(NM_HOME="$nm" python3 "$PARSER" --task pipe1 --kind ship --harness codex \
    --pipeline-branch fm/pipe1 --pipeline-project /pipe-proj)
  assert_equals '2' "$(jq -r .pipeline_runs <<<"$out")" "both same-branch runs are counted"
  assert_equals '6' "$(jq -r .pipeline_invocations <<<"$out")" "every same-branch invocation is counted"
  assert_equals '3500' "$(jq -r .pipeline_input_tokens <<<"$out")" "input tokens sum the reported invocations"
  assert_equals '1600' "$(jq -r .pipeline_output_tokens <<<"$out")" "output tokens sum the reported invocations"
  assert_equals '9100' "$(jq -r .pipeline_cache_read_tokens <<<"$out")" "cache-read tokens sum the reported invocations"
  assert_equals '110' "$(jq -r .pipeline_cache_creation_tokens <<<"$out")" "cache-creation tokens sum the reported invocations"
  assert_equals '100000' "$(jq -r .pipeline_agent_ms <<<"$out")" "agent duration sums the reported invocations"
  assert_equals '3' "$(jq -r .pipeline_unmeasured_invocations <<<"$out")" "the tokenless and killed invocations are counted, not priced"
  assert_equals '19000' "$(jq -r .pipeline_unmeasured_ms <<<"$out")" "the tokenless and killed invocations keep their duration"
  assert_equals 'partial' "$(jq -r .pipeline_cost_lane <<<"$out")" "an unpriced model marks the cost partial"
  jq -e '.pipeline_usd > 0.027 and .pipeline_usd < 0.028' <<<"$out" >/dev/null \
    || fail "the priced invocations did not carry their opus cost: $out"
  assert_contains "$(jq -r .pipeline_note <<<"$out")" "gpt-mystery" "the partial lane names the unpriced model"
  pass "pipeline columns count tokenless invocations with duration instead of pricing them zero"
}

test_pipeline_resolves_the_repo_by_the_task_worktree() {
  local nm out
  nm="$TMP_ROOT/nm-worktree-key"
  mkdir -p "$nm"
  NM_SEED="$nm/state.sqlite" python3 - <<'PY'
import os
import sqlite3
db = sqlite3.connect(os.environ["NM_SEED"])
db.execute("CREATE TABLE repos(id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE)")
db.execute("CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, created_at INTEGER NOT NULL)")
db.execute("CREATE TABLE agent_invocations(id TEXT PRIMARY KEY, run_id TEXT NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, duration_ms INTEGER)")
# The pipeline ran from inside the task's pooled worktree, so that is the path
# the inventory keys the repo by; the project clone is a known repo with no
# runs on this branch.
db.execute("INSERT INTO repos VALUES('rw','/treehouse/slot/firstmate/projects/sample')")
db.execute("INSERT INTO repos VALUES('rp','/pipe-proj')")
db.execute("INSERT INTO runs VALUES('runW','rw','fm/pipe1',1)")
db.execute("INSERT INTO agent_invocations VALUES('w1','runW','claude-opus-4-1',1000,500,9000,100,60000)")
db.commit()
db.close()
PY
  out=$(NM_HOME="$nm" python3 "$PARSER" --task pipe1 --kind ship --harness codex \
    --worktree /treehouse/slot/firstmate \
    --pipeline-branch fm/pipe1 --pipeline-project /pipe-proj)
  assert_equals '1' "$(jq -r .pipeline_runs <<<"$out")" "a run keyed by the task worktree is found"
  assert_equals 'api-equiv' "$(jq -r .pipeline_cost_lane <<<"$out")" "the worktree-keyed run is priced, not zeroed"
  jq -e '.pipeline_usd > 0' <<<"$out" >/dev/null \
    || fail "the worktree-keyed run carried no cost: $out"
  jq -e 'has("pipeline_note") | not' <<<"$out" >/dev/null \
    || fail "a fully priced pipeline must carry no note: $out"
  pass "pipeline runs recorded against the task worktree are attributed to the task"
}

test_pipeline_without_a_branch_is_definitively_empty() {
  local out
  out=$(NM_HOME="$TMP_ROOT/nm-absent" python3 "$PARSER" --task t --kind ship --harness codex \
    --pipeline-branch "" --pipeline-project /pipe-proj)
  assert_equals 'none' "$(jq -r .pipeline_cost_lane <<<"$out")" "no branch means no pipeline, not unknown"
  jq -e '.pipeline_runs == 0 and .pipeline_invocations == 0 and .pipeline_usd == null' <<<"$out" >/dev/null \
    || fail "an empty pipeline zeroes every column: $out"
  pass "a task with no branch records an empty pipeline"
}

test_pipeline_with_an_unresolvable_repo_is_unmeasured() {
  local nm out
  nm="$TMP_ROOT/nm-norepo"
  mkdir -p "$nm"
  NM_SEED="$nm/state.sqlite" python3 - <<'PY'
import os
import sqlite3
path = os.environ["NM_SEED"]
db = sqlite3.connect(path)
db.execute("CREATE TABLE repos(id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE)")
db.execute("CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, created_at INTEGER NOT NULL)")
db.execute("CREATE TABLE agent_invocations(id TEXT PRIMARY KEY, run_id TEXT NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, duration_ms INTEGER)")
db.commit()
db.close()
PY
  out=$(NM_HOME="$nm" python3 "$PARSER" --task t --kind ship --harness codex \
    --pipeline-branch fm/pipe1 --pipeline-project /no-such-project)
  assert_equals 'unmeasured' "$(jq -r .pipeline_cost_lane <<<"$out")" "an unresolvable repo stays unmeasured"
  [ -n "$(jq -r .pipeline_note <<<"$out")" ] \
    || fail "an unmeasured pipeline must state its reason"
  NM_HOME="$TMP_ROOT/nm-missing" python3 "$PARSER" --task t --kind ship --harness codex \
    --pipeline-branch fm/pipe1 --pipeline-project /pipe-proj > "$TMP_ROOT/po" 2>/dev/null \
    || fail "a missing inventory must still answer"
  assert_equals 'unmeasured' "$(jq -r .pipeline_cost_lane <"$TMP_ROOT/po")" "a missing inventory stays unmeasured"
  pass "an unresolvable pipeline scope records unmeasured with a reason"
}

test_killed_invocations_are_unmeasured_even_with_tokens() {
  local nm out
  nm=$(sp_nm_seed "$TMP_ROOT/nm-pipeline-killed")
  out=$(NM_HOME="$nm" python3 "$PARSER" --task pipe1 --kind ship --harness codex \
    --pipeline-branch fm/pipe1 --pipeline-project /pipe-proj)
  assert_equals '3500' "$(jq -r .pipeline_input_tokens <<<"$out")" "a cancelled invocation's tokens are never summed"
  assert_equals '1600' "$(jq -r .pipeline_output_tokens <<<"$out")" "an errored invocation's tokens are never summed"
  assert_equals '100000' "$(jq -r .pipeline_agent_ms <<<"$out")" "killed duration stays out of the measured agent time"
  jq -e '.pipeline_usd > 0.027 and .pipeline_usd < 0.028' <<<"$out" >/dev/null \
    || fail "a cancelled invocation on a priceable model was priced: $out"
  jq -e '.pipeline_note | contains("gpt-broken") | not' <<<"$out" >/dev/null \
    || fail "an errored invocation's model was named as unpriced: $out"
  pass "invocations killed with a cancelled or error exit status are unmeasured despite their tokens"
}

test_pipeline_without_an_exit_status_column_falls_back_to_the_token_test() {
  local nm out
  nm="$TMP_ROOT/nm-old-schema"
  mkdir -p "$nm"
  NM_SEED="$nm/state.sqlite" python3 - <<'PY'
import os
import sqlite3
db = sqlite3.connect(os.environ["NM_SEED"])
db.execute("CREATE TABLE repos(id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE)")
db.execute("CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, created_at INTEGER NOT NULL)")
db.execute("CREATE TABLE agent_invocations(id TEXT PRIMARY KEY, run_id TEXT NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, duration_ms INTEGER)")
db.execute("INSERT INTO repos VALUES('r1','/pipe-proj')")
db.execute("INSERT INTO runs VALUES('runA','r1','fm/pipe1',1)")
db.execute("INSERT INTO agent_invocations VALUES" +
           "('a1','runA','claude-opus-4-1',1000,500,9000,100,60000)," +
           "('a2','runA',NULL,NULL,NULL,NULL,NULL,4000)")
db.commit()
db.close()
PY
  out=$(NM_HOME="$nm" python3 "$PARSER" --task pipe1 --kind ship --harness codex \
    --pipeline-branch fm/pipe1 --pipeline-project /pipe-proj)
  assert_equals 'api-equiv' "$(jq -r .pipeline_cost_lane <<<"$out")" "an older inventory schema is still priced"
  assert_equals '1' "$(jq -r .pipeline_unmeasured_invocations <<<"$out")" "without exit_status the token test alone marks unmeasured"
  assert_equals '4000' "$(jq -r .pipeline_unmeasured_ms <<<"$out")" "the tokenless invocation keeps its duration"
  pass "an inventory without exit_status falls back to the reported-token test"
}

test_pipeline_with_nothing_priceable_is_unmeasured_not_partial() {
  local nm out
  nm="$TMP_ROOT/nm-nothing-priced"
  mkdir -p "$nm"
  NM_SEED="$nm/state.sqlite" python3 - <<'PY'
import os
import sqlite3
db = sqlite3.connect(os.environ["NM_SEED"])
db.execute("CREATE TABLE repos(id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE)")
db.execute("CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, created_at INTEGER NOT NULL)")
db.execute("CREATE TABLE agent_invocations(id TEXT PRIMARY KEY, run_id TEXT NOT NULL, model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER, duration_ms INTEGER, exit_status TEXT)")
db.execute("INSERT INTO repos VALUES('r1','/pipe-proj')")
db.execute("INSERT INTO runs VALUES('runA','r1','fm/pipe1',1)")
db.execute("INSERT INTO agent_invocations VALUES" +
           "('a1','runA','gpt-6-astra',1000,500,0,0,60000,'completed')," +
           "('a2','runA','',700,100,0,0,20000,'completed')")
db.commit()
db.close()
PY
  out=$(NM_HOME="$nm" python3 "$PARSER" --task pipe1 --kind ship --harness codex \
    --pipeline-branch fm/pipe1 --pipeline-project /pipe-proj)
  assert_equals 'unmeasured' "$(jq -r .pipeline_cost_lane <<<"$out")" "a pipeline with nothing priced is not partial"
  jq -e '.pipeline_usd == null' <<<"$out" >/dev/null \
    || fail "an unpriceable pipeline carried a cost: $out"
  assert_equals '1700' "$(jq -r .pipeline_input_tokens <<<"$out")" "unpriceable invocations keep their tokens"
  assert_contains "$(jq -r .pipeline_note <<<"$out")" "unknown" "an unrecorded model name is named rather than left blank"
  assert_contains "$(jq -r .pipeline_note <<<"$out")" "gpt-6-astra" "the note names every unpriced model"
  pass "a pipeline where no invocation could be priced records unmeasured, not partial"
}

test_normalize_line_reads_old_schema_lines() {
  local v1 v2 out
  v1='{"schema":1,"task":"old-1","kind":"ship","harness":"pi","model":"m","effort":"e","window":null,"calls":null,"mean_context_tokens":null,"cache_read_share":null,"usd_lane":"unmeasured","usd":null,"models":[],"unmeasured_reason":"r","ts":"2023-11-14T22:13:30Z","outcome":"pr","outcome_ref":"https://example.test/pr/1"}'
  out=$(printf '%s' "$v1" | python3 "$PARSER" --task ignored --normalize-line)
  assert_equals '2' "$(jq -r .schema <<<"$out")" "a schema 1 line normalizes to schema 2"
  assert_equals 'old-1' "$(jq -r .task <<<"$out")" "normalization keeps the task fields"
  assert_equals 'pr' "$(jq -r .outcome <<<"$out")" "normalization keeps the producer fields"
  assert_equals '0' "$(jq -r .pipeline_runs <<<"$out")" "a schema 1 line gains default pipeline columns"
  assert_equals 'unmeasured' "$(jq -r .pipeline_cost_lane <<<"$out")" "the default pipeline columns are unmeasured"
  v2=$(printf '%s' "$v1" | python3 "$PARSER" --task ignored --normalize-line)
  out=$(printf '%s' "$v2" | python3 "$PARSER" --task ignored --normalize-line)
  assert_equals "$v2" "$out" "a schema 2 line normalizes to itself"
  if printf '%s' '{"schema":9,"task":"x"}' | python3 "$PARSER" --task ignored --normalize-line >/dev/null 2>&1; then
    fail "an unknown ledger schema must be refused"
  fi
  pass "old-schema ledger lines still parse into the current schema"
}

test_claude_measures_deduped_window_bounded_api_equiv() {
  local home dir out
  home=$(sq_home claude-measured)
  dir=$(sq_claude_dir "$home" "$home/wt")
  # msg_1 appears twice (Claude writes one record per content block sharing
  # the message id); msg_early predates the spawn_gen epoch and msg_late
  # postdates the end bound, so both must be excluded.
  {
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:13:30.000Z","message":{"id":"msg_1","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":98000,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":0}}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:14:00.000Z","message":{"id":"msg_1","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":98000,"cache_creation_input_tokens":1000}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:20:00.000Z","message":{"id":"msg_2","model":"claude-sonnet-4","usage":{"input_tokens":2000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T21:00:00.000Z","message":{"id":"msg_early","model":"claude-opus-4-1","usage":{"input_tokens":99999,"output_tokens":9999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2030-01-01T00:00:00.000Z","message":{"id":"msg_late","model":"claude-opus-4-1","usage":{"input_tokens":88888,"output_tokens":888,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
  } > "$dir/s1.jsonl"
  sq_meta "$home" task-a1

  out=$(sq_query "$home" task-a1)
  assert_equals '2' "$(jq -r .calls <<<"$out")" "duplicate message ids count as one call and out-of-window records are excluded"
  assert_equals '51000' "$(jq -r .mean_context_tokens <<<"$out")" "mean context tokens average input, cache read, and cache write"
  assert_equals '0.961' "$(jq -r .cache_read_share <<<"$out")" "cache-read share is computed over the window's context tokens"
  assert_equals 'api-equiv' "$(jq -r .usd_lane <<<"$out")" "Claude Code logs no price, so the lane is api-equiv"
  jq -e '.usd > 0.08 and .usd < 0.081' <<<"$out" >/dev/null \
    || fail "api-equiv USD did not match the assumed-rate pricing: $out"
  assert_equals 'claude-opus-4-1
claude-sonnet-4' "$(jq -r '.models | join("\n")' <<<"$out")" "models seen in the window are listed sorted"
  assert_equals '1700000000' "$(jq -r .window.start_epoch <<<"$out")" "the window starts at the spawn_gen epoch"
  jq -e '.window.end_epoch > 1700000000' <<<"$out" >/dev/null \
    || fail "the window end bound is missing"
  pass "claude logs measure api-equiv spend with id dedupe and mandatory window bounding"
}

# --- Pi measurement: the runtime's own recorded cost --------------------------

test_pi_records_the_runtime_cost() {
  local home dir out
  home=$(sq_home pi-measured)
  dir=$(sq_pi_dir "$home" "$home/wt")
  {
    printf '%s\n' '{"type":"session","version":3,"id":"s1","timestamp":"2023-11-14T22:13:25.000Z","cwd":"'"$home"'/wt"}'
    printf '%s\n' '{"type":"message","id":"m1","timestamp":"2023-11-14T22:13:30.000Z","message":{"role":"assistant","model":"glm-5.3","usage":{"input":35578,"output":3549,"cacheRead":4032,"cacheWrite":0,"cost":{"total":0.0665}}}}'
    printf '%s\n' '{"type":"message","id":"m2","timestamp":"2023-11-14T22:14:10.000Z","message":{"role":"assistant","model":"glm-5.3","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.002}}}}'
    printf '%s\n' '{"type":"message","id":"m3","timestamp":"2023-11-14T20:00:00.000Z","message":{"role":"assistant","model":"glm-5.3","usage":{"input":999,"output":99,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.5}}}}'
  } > "$dir/2023-11-14T22-13-25-000Z_s1.jsonl"
  sq_meta "$home" task-b2 harness=pi model=glm-5.3 effort=max

  out=$(sq_query "$home" task-b2)
  assert_equals 'recorded' "$(jq -r .usd_lane <<<"$out")" "Pi logs its own cost, so the lane is recorded"
  assert_equals '0.0685' "$(jq -r .usd <<<"$out")" "the recorded cost is summed over the window only"
  assert_equals '2' "$(jq -r .calls <<<"$out")" "Pi assistant messages each carry one usage record"
  pass "pi logs record the runtime's own cost in the recorded lane"
}

# --- Unmeasured paths ---------------------------------------------------------

test_uncovered_runtime_records_explicit_reason() {
  local home out
  home=$(sq_home claude-uncovered)
  sq_meta "$home" task-c3 harness=codex model=gpt-5 effort=high
  out=$(sq_query "$home" task-c3)
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "a runtime without a verified parser is unmeasured"
  assert_equals 'null' "$(jq -r .usd <<<"$out")" "an unmeasured line carries no USD figure"
  [ -n "$(jq -r .unmeasured_reason <<<"$out")" ] \
    || fail "an unmeasured line must state its reason"
  pass "a runtime without a verified parser records an explicit unmeasured reason"
}

test_pi_signed_uses_the_pi_parser() {
  local home out
  home=$(sq_home claude-pi-signed)
  sq_meta "$home" task-p1 harness=pi-signed model=glm-5.3 effort=max
  out=$(sq_query "$home" task-p1)
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "pi-signed parses Pi logs, so an empty log dir is the no-records reason"
  assert_contains "$(jq -r .unmeasured_reason <<<"$out")" "no session log" "pi-signed resolves Pi's session directory"
  pass "pi-signed routes to Pi's session-log location"
}

test_missing_session_logs_record_unmeasured_with_window() {
  local home out
  home=$(sq_home claude-missing-logs)
  sq_meta "$home" task-d4
  out=$(sq_query "$home" task-d4)
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "missing session logs are unmeasured"
  assert_contains "$(jq -r .unmeasured_reason <<<"$out")" "no session log directory" "the missing-log reason names the resolution failure"
  assert_equals '1700000000' "$(jq -r .window.start_epoch <<<"$out")" "the window is still reported when the logs are missing"
  pass "missing session logs record an explicit unmeasured line with the window"
}

# --- Wrapper record resolution --------------------------------------------------

test_wrapper_answers_unmeasured_without_an_epoch_shaped_spawn_gen() {
  local home out
  home=$(sq_home claude-mtime)
  sq_meta "$home" task-e5
  # Drop the spawn_gen line so no epoch-shaped spawn stamp bounds the window:
  # the record is appended to throughout the task's life, so its mtime sits
  # near the task's end, and a window that starts there would price a final
  # slice of the task's calls as the whole task.
  grep -v '^spawn_gen=' "$home/state/task-e5.meta" > "$home/state/task-e5.meta.tmp"
  mv "$home/state/task-e5.meta.tmp" "$home/state/task-e5.meta"
  out=$(sq_query "$home" task-e5)
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "a record without an epoch-shaped spawn_gen is unmeasured, not partially measured"
  assert_contains "$(jq -r .unmeasured_reason <<<"$out")" "no spawn epoch on record" "the unmeasured reason names the unbounded window"
  assert_equals 'null' "$(jq -r .window <<<"$out")" "no window is claimed when it cannot be bounded"
  pass "the query answers unmeasured when no epoch-shaped spawn_gen bounds the window"
}

test_relaunched_task_bounds_the_window_at_its_first_spawn() {
  local home dir out
  home=$(sq_home claude-relaunched)
  dir=$(sq_claude_dir "$home" "$home/wt")
  # A relaunched record: spawn_gen is the second incarnation's stamp, while
  # spawn_epoch_first still names the first incarnation's epoch.
  sq_meta "$home" task-r9 'spawn_gen=s1700009000.9.z' 'spawn_epoch_first=1700000000'
  printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:13:30.000Z","message":{"id":"msg_first","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
    > "$dir/first.jsonl"
  printf '%s\n' '{"type":"assistant","timestamp":"2023-11-15T00:43:30.000Z","message":{"id":"msg_second","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
    > "$dir/second.jsonl"
  out=$(sq_query "$home" task-r9)
  assert_equals '1700000000' "$(jq -r .window.start_epoch <<<"$out")" "the window starts at the first incarnation's epoch"
  assert_equals '2' "$(jq -r .calls <<<"$out")" "both incarnations' calls are measured"
  pass "a relaunched task measures every incarnation from spawn_epoch_first"
}

test_record_without_a_first_epoch_falls_back_to_spawn_gen() {
  local home dir out
  home=$(sq_home claude-no-first-epoch)
  dir=$(sq_claude_dir "$home" "$home/wt")
  # The fixture record carries spawn_gen only, as a pre-spawn_epoch_first
  # record does.
  sq_meta "$home" task-r10
  printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:13:30.000Z","message":{"id":"msg_1","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' \
    > "$dir/s1.jsonl"
  out=$(sq_query "$home" task-r10)
  assert_equals '1700000000' "$(jq -r .window.start_epoch <<<"$out")" "without spawn_epoch_first the window falls back to the spawn_gen epoch"
  assert_equals '1' "$(jq -r .calls <<<"$out")" "the fallback window still measures the task's calls"
  pass "a record without spawn_epoch_first bounds the window at its spawn_gen epoch"
}

test_successor_calls_after_the_task_activity_bound_are_excluded() {
  local home dir out
  home=$(sq_home claude-pooled-slot)
  dir=$(sq_claude_dir "$home" "$home/wt")
  # The task's own call, then a successor task's call in the same pooled-slot
  # log directory after this task's last activity sidecar touch.
  {
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:13:30.000Z","message":{"id":"mine","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T23:30:00.000Z","message":{"id":"successor","model":"claude-opus-4-1","usage":{"input_tokens":900000,"output_tokens":90000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
  } > "$dir/s1.jsonl"
  sq_meta "$home" task-p1
  TZ=UTC0 touch -t 202311142230 "$home/state/task-p1.turn-ended"

  out=$(sq_query "$home" task-p1)
  assert_equals '1' "$(jq -r .calls <<<"$out")" "a successor task's later calls in the same pooled slot are excluded"
  assert_equals '1700000000' "$(jq -r .window.start_epoch <<<"$out")" "the window still starts at the task's first spawn epoch"
  assert_equals '1700001000' "$(jq -r .window.end_epoch <<<"$out")" "the window ends at the newest task-owned activity sidecar mtime"
  jq -e '.usd < 0.02' <<<"$out" >/dev/null \
    || fail "the successor's tokens were priced into this task's figure: $out"
  pass "the measured window ends at the task's own activity bound, not at teardown time"
}

test_final_call_inside_the_bound_second_is_measured() {
  local home dir out
  home=$(sq_home claude-bound-second)
  dir=$(sq_claude_dir "$home" "$home/wt")
  # The turn's last call at 22:30:00.400Z, then the turn-end touch landing
  # later in that same wall-clock second; the mtime is whole seconds, so the
  # last call must still count. The successor's call a second later must not.
  {
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:13:30.000Z","message":{"id":"mid","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:30:00.400Z","message":{"id":"last","model":"claude-opus-4-1","usage":{"input_tokens":4000,"output_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
    printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:30:01.000Z","message":{"id":"successor","model":"claude-opus-4-1","usage":{"input_tokens":900000,"output_tokens":90000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
  } > "$dir/s1.jsonl"
  sq_meta "$home" task-p4
  TZ=UTC0 touch -t 202311142230 "$home/state/task-p4.turn-ended"

  out=$(sq_query "$home" task-p4)
  assert_equals '2' "$(jq -r .calls <<<"$out")" "the turn's final call inside the bound's own second is measured"
  assert_equals '1700001000' "$(jq -r .window.end_epoch <<<"$out")" "the reported end bound stays the sidecar mtime"
  jq -e '.usd < 0.1' <<<"$out" >/dev/null \
    || fail "a record past the bound's second was priced into the figure: $out"
  pass "the end bound covers its whole second, so the turn's last call is not dropped"
}

test_record_without_an_activity_sidecar_is_unmeasured() {
  local home dir out
  home=$(sq_home claude-no-sidecar)
  dir=$(sq_claude_dir "$home" "$home/wt")
  printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:13:30.000Z","message":{"id":"m1","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$dir/s1.jsonl"
  sq_meta "$home" task-p2
  rm -f "$home/state/task-p2.turn-ended"

  out=$(sq_query "$home" task-p2)
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "without a task-owned activity bound the answer is unmeasured"
  assert_contains "$(jq -r .unmeasured_reason <<<"$out")" "no task-owned activity bound" "the reason names the missing bound"
  pass "a record with no activity sidecar records an explicit unmeasured line"
}

test_progress_sidecar_alone_bounds_the_window() {
  local home dir out
  home=$(sq_home claude-progress-bound)
  dir=$(sq_claude_dir "$home" "$home/wt")
  printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:13:30.000Z","message":{"id":"m1","model":"claude-opus-4-1","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$dir/s1.jsonl"
  sq_meta "$home" task-p3
  rm -f "$home/state/task-p3.turn-ended"
  TZ=UTC0 touch -t 202311142240 "$home/state/task-p3.progress"

  out=$(sq_query "$home" task-p3)
  assert_equals '1' "$(jq -r .calls <<<"$out")" "the progress sidecar alone bounds a measurable window"
  assert_equals '1700001600' "$(jq -r .window.end_epoch <<<"$out")" "the progress sidecar mtime is the window end"
  pass "either activity sidecar can bound the window"
}

test_unmeasured_flag_emits_the_schema_shape() {
  local home out
  home=$(sq_home claude-unmeasured-flag)
  sq_meta "$home" task-h8
  out=$(FM_STATE_OVERRIDE="$home/state" "$QUERY" --unmeasured 'spend query failed' task-h8)
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "--unmeasured emits the unmeasured lane"
  assert_equals 'spend query failed' "$(jq -r .unmeasured_reason <<<"$out")" "--unmeasured carries the caller's reason"
  assert_equals 'task-h8' "$(jq -r .task <<<"$out")" "--unmeasured keeps the record's own fields"
  assert_equals 'claude' "$(jq -r .harness <<<"$out")" "--unmeasured reads the task record's harness"
  FM_STATE_OVERRIDE="$home/state" "$QUERY" --unmeasured 'any reason' no-such-task >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 2 ] || fail "--unmeasured without a task record must refuse"
  FM_STATE_OVERRIDE="$home/state" "$QUERY" --unmeasured '' task-h8 >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "--unmeasured with an empty reason must refuse instead of measuring"
  pass "the --unmeasured flag emits the schema shape without measuring"
}

test_wrapper_refuses_bad_invocations() {
  local home out rc
  home=$(sq_home claude-refusals)
  sq_meta "$home" task-f6
  sq_query "$home" nope > "$TMP_ROOT/o1" 2> "$TMP_ROOT/e1"
  rc=$?
  expect_code 2 "$rc" "a missing task record refuses with exit 2"
  assert_contains "$(cat "$TMP_ROOT/e1")" "no readable task record" "a missing record names the record path"
  HOME="$home/home" FM_STATE_OVERRIDE="$home/state" "$QUERY" 'bad id;' >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a malformed task id refuses with exit 2"
  HOME="$home/home" FM_STATE_OVERRIDE="$home/state" "$QUERY" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a missing task id argument refuses with exit 2"
  HOME="$home/home" FM_STATE_OVERRIDE="$home/state" "$QUERY" --help > "$TMP_ROOT/o2" 2>&1
  assert_contains "$(cat "$TMP_ROOT/o2")" "fm-spend-query.sh" "help prints the command contract"
  pass "the wrapper refuses malformed invocations without reading logs"
}

test_wrapper_falls_back_to_unmeasured_without_python3() {
  local home shadow cmd out rc
  home=$(sq_home claude-nopython)
  sq_meta "$home" task-g7
  # Build a PATH without python3 so the wrapper's own fallback answers.
  shadow="$TMP_ROOT/nopython-bin"
  mkdir -p "$shadow"
  for cmd in bash jq sed stat uname date cat tail dirname basename head grep; do
    cmd=$(command -v "$cmd" 2>/dev/null) || continue
    case "$cmd" in /*) ln -sf "$cmd" "$shadow/$(basename "$cmd")" ;; esac
  done
  out=$(PATH="$shadow" HOME="$home/home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$QUERY" task-g7)
  rc=$?
  expect_code 0 "$rc" "the wrapper still answers when python3 is absent"
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "the no-python3 fallback records unmeasured"
  assert_contains "$(jq -r .unmeasured_reason <<<"$out")" "python3" "the no-python3 fallback names the cause"
  assert_equals 'task-g7' "$(jq -r .task <<<"$out")" "the fallback keeps the schema's fields"
  pass "without python3 the wrapper answers with the schema's unmeasured shape"
}

# --- Brief composition ---------------------------------------------------------

test_brief_composition_splits_scaffold_from_task() {
  local dir out
  dir="$TMP_ROOT/composition"
  mkdir -p "$dir"
  # 40 chars of scaffold text, then 40 chars the intake added.
  {
    printf 'fixed header line that is scaffold only\n'
    printf 'body line shared with the scaffold\n'
    printf 'captain words unique to this task\n'
  } > "$dir/brief.md"
  {
    printf 'fixed header line that is scaffold only\n'
    printf 'body line shared with the scaffold\n'
    printf 'placeholder line only in the scaffold\n'
  } > "$dir/scaffold.md"
  out=$("$COMPOSITION" "$dir/brief.md" "$dir/scaffold.md")
  jq -e '.scaffold_tokens == 18 and .task_tokens == 8 and .fixed_share == 0.688' <<<"$out" >/dev/null \
    || fail "composition split did not match the char/4 line-match measure: $out"
  pass "the composition measure splits the filled brief into scaffold and task tokens"
}

test_brief_composition_maps_probe_paths_onto_the_real_home() {
  local dir out unmapped reversed rc
  dir="$TMP_ROOT/composition-map"
  mkdir -p "$dir"
  # The real brief bakes the live home's absolute paths; the probe scaffold
  # bakes the throwaway probe home's. Only the path map makes those scaffold
  # lines compare equal, so only the intake's own line is task-specific.
  {
    printf 'shared plain scaffold line\n'
    printf 'append status to /real/state/task.status when the turn ends\n'
    printf 'read the inbox at /real/data/task/inbox.md before replying\n'
    printf 'captain words unique to this task\n'
  } > "$dir/brief.md"
  {
    printf 'shared plain scaffold line\n'
    printf 'append status to /probe/state/task.status when the turn ends\n'
    printf 'read the inbox at /probe/task/inbox.md before replying\n'
    printf 'placeholder line only in the scaffold\n'
  } > "$dir/scaffold.md"

  out=$("$COMPOSITION" "$dir/brief.md" "$dir/scaffold.md" \
    --map '/probe/state=/real/state' --map '/probe=/real/data')
  assert_equals '8' "$(jq -r .task_tokens <<<"$out")" "with the path map only the intake's own line is task-specific"

  # Longest source first is the measure's own rule: the state mapping must win
  # over the home mapping whatever order the caller passes them in.
  reversed=$("$COMPOSITION" "$dir/brief.md" "$dir/scaffold.md" \
    --map '/probe=/real/data' --map '/probe/state=/real/state')
  assert_equals "$out" "$reversed" "the map is applied longest source first regardless of argument order"

  unmapped=$("$COMPOSITION" "$dir/brief.md" "$dir/scaffold.md")
  jq -e --argjson mapped "$(jq -r .task_tokens <<<"$out")" '.task_tokens > $mapped' <<<"$unmapped" >/dev/null \
    || fail "without the map the baked path lines must count as task-specific: $unmapped"
  jq -e --argjson mapped "$(jq -r .fixed_share <<<"$out")" '.fixed_share < $mapped' <<<"$unmapped" >/dev/null \
    || fail "without the map the fixed share must be understated: $unmapped"

  "$COMPOSITION" "$dir/brief.md" "$dir/scaffold.md" --map >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "--map without a value must refuse instead of measuring unmapped"
  pass "the scaffold path map makes the probe home's baked paths count as scaffold"
}

test_brief_composition_refuses_unreadable_inputs() {
  local dir rc
  dir="$TMP_ROOT/composition-bad"
  mkdir -p "$dir"
  printf 'content\n' > "$dir/brief.md"
  "$COMPOSITION" "$dir/brief.md" "$dir/missing.md" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a missing scaffold refuses instead of printing a guess"
  "$COMPOSITION" "$dir/missing.md" "$dir/brief.md" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a missing brief refuses instead of printing a guess"
  pass "the composition measure refuses unreadable inputs"
}

test_parser_direct_invocation_bounds_with_explicit_window() {
  local home dir out rc
  home=$(sq_home claude-explicit-window)
  dir=$(sq_claude_dir "$home" "$home/wt")
  printf '%s\n' '{"type":"assistant","timestamp":"2023-11-14T22:13:30.000Z","message":{"id":"m1","model":"claude-opus-4-1","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$dir/s.jsonl"
  out=$(HOME="$home/home" python3 "$PARSER" --task t --harness claude --worktree "$home/wt" \
    --spawn-epoch 1700000000 --end-epoch 1700000100)
  assert_equals '1' "$(jq -r .calls <<<"$out")" "an explicit window admits in-window records"
  out=$(HOME="$home/home" python3 "$PARSER" --task t --harness claude --worktree "$home/wt" \
    --spawn-epoch 1700000400 --end-epoch 1700000500)
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "a record outside an explicit window is excluded"
  HOME="$home/home" python3 "$PARSER" --task t --harness claude --worktree "$home/wt" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a measurement without window bounds must refuse instead of summing the pooled worktree"
  HOME="$home/home" python3 "$PARSER" --task t --harness claude --worktree "$home/wt" \
    --spawn-epoch 1700000000 >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a measurement with only a start bound must refuse"
  out=$(HOME="$home/home" python3 "$PARSER" --task t --harness codex --worktree "$home/wt")
  assert_equals 'unmeasured' "$(jq -r .usd_lane <<<"$out")" "an uncovered runtime still answers unmeasured without bounds"
  pass "the parser honors explicitly bounded windows and refuses an unbounded measurement"
}

test_claude_measures_deduped_window_bounded_api_equiv
test_pi_records_the_runtime_cost
test_uncovered_runtime_records_explicit_reason
test_pi_signed_uses_the_pi_parser
test_missing_session_logs_record_unmeasured_with_window
test_wrapper_answers_unmeasured_without_an_epoch_shaped_spawn_gen
test_relaunched_task_bounds_the_window_at_its_first_spawn
test_record_without_a_first_epoch_falls_back_to_spawn_gen
test_successor_calls_after_the_task_activity_bound_are_excluded
test_final_call_inside_the_bound_second_is_measured
test_record_without_an_activity_sidecar_is_unmeasured
test_progress_sidecar_alone_bounds_the_window
test_unmeasured_flag_emits_the_schema_shape
test_wrapper_refuses_bad_invocations
test_wrapper_falls_back_to_unmeasured_without_python3
test_brief_composition_splits_scaffold_from_task
test_brief_composition_maps_probe_paths_onto_the_real_home
test_brief_composition_refuses_unreadable_inputs
test_parser_direct_invocation_bounds_with_explicit_window
test_pipeline_counts_measured_and_null_token_invocations
test_pipeline_resolves_the_repo_by_the_task_worktree
test_pipeline_without_a_branch_is_definitively_empty
test_pipeline_with_an_unresolvable_repo_is_unmeasured
test_killed_invocations_are_unmeasured_even_with_tokens
test_pipeline_without_an_exit_status_column_falls_back_to_the_token_test
test_pipeline_with_nothing_priceable_is_unmeasured_not_partial
test_normalize_line_reads_old_schema_lines

echo "OK: fm-spend-query"
