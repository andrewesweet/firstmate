#!/usr/bin/env bash
# tests/fm-backend-herdr-metadata.test.sh - display-only Herdr pane metadata
# projection (bin/backends/herdr-metadata.sh, entered through
# bin/fm-herdr-metadata.sh). Mirrors tests/fm-backend-herdr.test.sh's
# fakebin/command-log convention: a LOG-based fake `herdr` with numbered canned
# responses, a fake bin/fm-crew-state.sh, and exact-argument assertions on the
# issued `pane report-metadata` calls. The projection contract under test:
# fields come from the task's durable records only, every write is binding-
# validated against the recorded endpoint, tokens stay inside the fm_
# namespace, and every failure is a one-line diagnostic that never blocks a
# caller. The real-binary exercise is optional per the brief and lives with the
# other Herdr suites; these stub tests are the primary coverage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-metadata-tests)
mkdir -p "$TMP_ROOT/ambient-home"
export FM_HOME="$TMP_ROOT/ambient-home"
export FM_BACKEND_HERDR_METADATA_NOW=1700000000

ENTRY="$ROOT/bin/fm-herdr-metadata.sh"

# make_metadata_fakebin: the numbered-response fake herdr (same convention as
# tests/fm-backend-herdr.test.sh): every invocation is logged one-per-line to
# $FM_HERDR_LOG with unit-separated args, and call N reads $FM_HERDR_RESPONSES/N.out
# (and N.exit when present). A missing response file is a silent success.
make_metadata_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
fm_log_line="HERDR_SESSION=${HERDR_SESSION:-}"
for a in "$@"; do fm_log_line="$fm_log_line"$'\x1f'"$a"; done
printf '%s\n' "$fm_log_line" >> "$LOG"
n=$next
echo "$n" > "$COUNT_FILE"
[ -f "$RESP/$n.err" ] && cat "$RESP/$n.err" >&2
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_metadata_task <dir> <id> [key=val ...]: a task home with a brief whose
# Captain's intent is a fixed line, and a Herdr meta record. Extra key=val
# pairs are appended to the meta. Echoes the home dir.
make_metadata_task() {  # <dir> <id> [key=val ...]
  local dir=$1 id=$2 kv home="$1/home"
  mkdir -p "$home/data/$id" "$home/state"
  printf '%s\n' '# Task' '' "## Captain's intent" '' 'Ship the pane metadata fix' '' \
    '## Firstmate spec' '' 'Do the thing.' > "$home/data/$id/brief.md"
  : > "$home/state/$id.meta"
  printf '%s\n' "window=hs:w1:p2" "endpoint_task_id=$id" \
    "worktree=$home/wt" "project=$home/proj" "harness=pi" "kind=ship" \
    "backend=herdr" "herdr_session=hs" "herdr_workspace_id=ws1" \
    "herdr_tab_id=t1" "herdr_pane_id=w1:p2" >> "$home/state/$id.meta"
  shift 2
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$home/state/$id.meta"
  done
  printf '%s\n' "$home"
}

# make_crew_state <dir> <line>: a fake bin/fm-crew-state.sh printing one canned
# state line; its exit code is nonzero when the line is the literal FAIL.
make_crew_state() {  # <dir> <line>
  local dir=$1 line=$2 script="$1/crew-state"
  cat > "$script" <<SH
#!/usr/bin/env bash
[ -n "\${FM_CREW_STATE_LOG:-}" ] && printf '%s\n' "\$*" >> "\$FM_CREW_STATE_LOG"
case "$line" in
  FAIL) exit 3 ;;
esac
printf '%s\n' '$line'
SH
  chmod +x "$script"
}

# pane_get_ok / pane_get_mismatch: canned `pane get` bodies for call 1.
pane_get_ok='{"result":{"pane":{"pane_id":"w1:p2","workspace_id":"ws1","tab_id":"t1"}}}'
pane_get_mismatch='{"result":{"pane":{"pane_id":"w1:p2","workspace_id":"ws9","tab_id":"t1"}}}'

# run_publish <home> <id> <fakebin> [RESP-file bodies pre-seeded by caller]
run_publish() {  # <home> <id> <fakebin> [extra env assignments as VAR=val ...]
  local home=$1 id=$2 fb=$3; shift 3
  (
    # The fixture env is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export PATH="$fb:$PATH" FM_HOME="$home"
    # shellcheck disable=SC2030,SC2031
    export FM_BACKEND_HERDR_METADATA_NOW=1700000000
    for a in "$@"; do export "${a?}"; done
    "$ENTRY" publish "$id"
  )
}

# expected source id for a home path
expected_source() {  # <home>
  printf 'firstmate:%s-%s' "${1##*/}" \
    "$(printf '%s' "$1" | cksum | cut -d' ' -f1 | cut -c1-8)"
}

# --- field projection --------------------------------------------------------

test_publish_projects_exact_fields_from_records() {
  local dir home fb log resp out rc
  dir="$TMP_ROOT/projection"; home=$(make_metadata_task "$dir" task-a \
    "pr=https://github.com/example/repo/pull/7")
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: parked · source: status-log · awaiting your merge decision'

  out=$(run_publish "$home" task-a "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" 2>&1)
  rc=$?
  expect_code 0 "$rc" "projection: publish should succeed, got: $out"
  [ -z "$out" ] || fail "projection: a successful publish must stay silent, got: $out"
  assert_contains "$(cat "$log")" $'\x1f--source\x1f'"$(expected_source "$home")" \
    "projection: the write must name this home's own sequenced source"
  assert_contains "$(cat "$log")" $'\x1f--display-agent\x1ffirstmate ship' \
    "projection: the display agent must project kind from the record"
  assert_contains "$(cat "$log")" $'\x1f--token\x1ffm_task=task-a' \
    "projection: the task id token must always be set"
  assert_contains "$(cat "$log")" $'\x1f--token\x1ffm_pr=https://github.com/example/repo/pull/7' \
    "projection: a recorded PR URL must be projected verbatim"
  assert_contains "$(cat "$log")" $'\x1f--clear-token\x1ffm_report' \
    "projection: a ship task's report pointer must be cleared, never set"
  assert_contains "$(cat "$log")" $'\x1f--token\x1ffm_wait=decision: awaiting your merge decision' \
    "projection: a parked task's held decision must become the fm_wait marker"
  assert_contains "$(cat "$log")" $'\x1f--title\x1ffm-task-a: [decision] Ship the pane metadata fix' \
    "projection: the title must read fm-<id>: [marker] intent"
  assert_contains "$(cat "$log")" $'\x1f--ttl-ms\x1f86400000' \
    "projection: set tokens carry the generous TTL backstop"
  assert_contains "$(cat "$log")" $'\x1f--seq\x1f1700000000' \
    "projection: the write must be sequenced for ordering"
  assert_contains "$(cat "$log")" $'w1:p2\x1f--session\x1fhs' \
    "projection: the write must target the recorded pane on the recorded session"
  pass "publish projects task/role, intent, wait marker, and PR pointer from the records"
}

test_publish_clears_marker_and_pointer_when_state_has_no_wait() {
  local dir home fb log resp
  dir="$TMP_ROOT/working"; home=$(make_metadata_task "$dir" task-b)
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: working · source: herdr-pane'

  run_publish "$home" task-b "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" >/dev/null 2>&1 \
    || fail "working-state publish should succeed"
  assert_contains "$(cat "$log")" $'\x1f--clear-token\x1ffm_wait' \
    "working-state publish must clear the wait marker"
  assert_contains "$(cat "$log")" $'\x1f--clear-token\x1ffm_pr' \
    "a record without pr= must clear the PR pointer, never leave it stale"
  assert_contains "$(cat "$log")" $'\x1f--title\x1ffm-task-b: Ship the pane metadata fix' \
    "a working task's title must carry no marker tag"
  pass "a working task with no PR clears its marker and pointer instead of leaving them stale"
}

test_publish_marks_review_ready_and_scout_report_ready() {
  local dir home fb log resp
  dir="$TMP_ROOT/review"; home=$(make_metadata_task "$dir" task-c \
    "pr=https://github.com/example/repo/pull/9")
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: done · source: status-log · PR https://github.com/example/repo/pull/9 checks green'

  run_publish "$home" task-c "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" >/dev/null 2>&1 \
    || fail "review-ready publish should succeed"
  assert_contains "$(cat "$log")" $'\x1f--token\x1ffm_wait=review ready' \
    "a done task with a PR must project the review-ready marker"
  assert_contains "$(cat "$log")" $'\x1f--title\x1ffm-task-c: [review] Ship the pane metadata fix' \
    "the review-ready marker must tag the title"

  dir="$TMP_ROOT/scout"; home=$(make_metadata_task "$dir" task-d kind=scout)
  mkdir -p "$home/data/task-d"
  printf 'findings\n' > "$home/data/task-d/report.md"
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  make_crew_state "$dir" 'state: done · source: status-log · findings delivered'

  run_publish "$home" task-d "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" >/dev/null 2>&1 \
    || fail "scout-report publish should succeed"
  assert_contains "$(cat "$log")" $'\x1f--token\x1ffm_report=data/task-d/report.md' \
    "a finished scout with a report must project the durable report pointer"
  assert_contains "$(cat "$log")" $'\x1f--token\x1ffm_wait=report ready' \
    "a finished scout must project the report-ready marker"
  pass "done states project review-ready and report-ready markers with their pointers"
}

test_publish_clips_long_intents_and_secondmate_charters() {
  local dir home fb log resp long_intent title_args
  dir="$TMP_ROOT/clipping"; home=$(make_metadata_task "$dir" task-e)
  long_intent=$(printf 'x%.0s' $(seq 1 200))
  printf '%s\n' '# Task' '' "## Captain's intent" '' "$long_intent tail" > "$home/data/task-e/brief.md"
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: working · source: herdr-pane'

  run_publish "$home" task-e "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" >/dev/null 2>&1 \
    || fail "long-intent publish should succeed"
  title_args=$(sed -n 's/.*\x1f--title\x1f\([^\x1f]*\).*/\1/p' "$log")
  [ "${#title_args}" -le 80 ] || fail "clipping: title exceeded the 80-char cap (${#title_args}): $title_args"
  assert_contains "$title_args" 'fm-task-e: x' \
    "clipping: the clipped title must keep the task-id lead"

  dir="$TMP_ROOT/secondmate"; home="$dir/home"
  mkdir -p "$home/data" "$home/state" "$home/charter-home/data"
  printf '%s\n' '# Task' '' "## Captain's intent" '' 'Hold the alpha backlog' > "$home/charter-home/data/charter.md"
  : > "$home/state/mate-1.meta"
  printf '%s\n' "window=hs:m1:p1" "endpoint_task_id=mate-1" "kind=secondmate" \
    "backend=herdr" "herdr_session=hs" "herdr_workspace_id=ws1" \
    "herdr_tab_id=t1" "herdr_pane_id=m1:p1" "home=$home/charter-home" \
    >> "$home/state/mate-1.meta"
  log="$dir/log"; resp="$dir/resp2"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' '{"result":{"pane":{"pane_id":"m1:p1","workspace_id":"ws1","tab_id":"t1"}}}' > "$resp/1.out"
  make_crew_state "$dir" 'state: working · source: herdr-pane'

  run_publish "$home" mate-1 "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" >/dev/null 2>&1 \
    || fail "secondmate publish should succeed"
  assert_contains "$(cat "$log")" $'\x1f--title\x1ffm-mate-1: Hold the alpha backlog' \
    "a secondmate's intent must come from its recorded charter home"
  assert_contains "$(cat "$log")" $'\x1f--display-agent\x1ffirstmate secondmate' \
    "a secondmate's display agent must name its role"
  pass "titles clip to the API cap and secondmate charters project their intent"
}

# --- binding validation ------------------------------------------------------

test_publish_refuses_binding_mismatch_without_writing() {
  local dir home fb log resp out rc
  dir="$TMP_ROOT/mismatch"; home=$(make_metadata_task "$dir" task-f)
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_mismatch" > "$resp/1.out"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: parked · source: status-log · awaiting a decision'

  out=$(run_publish "$home" task-f "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" 2>&1)
  rc=$?
  expect_code 1 "$rc" "mismatch: publish must refuse, got: $out"
  assert_contains "$out" 'binding mismatch' \
    "mismatch: the refusal must name the binding check"
  assert_not_contains "$(cat "$log")" 'report-metadata' \
    "mismatch: no metadata write may follow a failed binding check"
  pass "a pane whose live workspace disagrees with the record refuses the write"
}

test_publish_refuses_gone_and_unvalidatable_panes() {
  local dir home fb log resp out rc
  dir="$TMP_ROOT/gone"; home=$(make_metadata_task "$dir" task-g)
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$resp/1.out"
  printf '%s\n' 1 > "$resp/1.exit"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: working · source: herdr-pane'

  out=$(run_publish "$home" task-g "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" 2>&1)
  rc=$?
  expect_code 1 "$rc" "gone: publish must refuse, got: $out"
  assert_not_contains "$(cat "$log")" 'report-metadata' \
    "gone: a vanished pane receives no write"

  dir="$TMP_ROOT/legacy"; home=$(make_metadata_task "$dir" task-h)
  grep -v '^herdr_workspace_id=\|^herdr_tab_id=' "$home/state/task-h.meta" > "$home/state/task-h.meta.new"
  mv "$home/state/task-h.meta.new" "$home/state/task-h.meta"
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  out=$(run_publish "$home" task-h "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" 2>&1)
  rc=$?
  expect_code 1 "$rc" "legacy: publish must refuse an unvalidatable record, got: $out"
  assert_contains "$out" 'unvalidatable' \
    "legacy: the refusal must name the missing binding fields"
  assert_not_contains "$(cat "$log")" 'report-metadata' \
    "legacy: no write may follow a failed binding check"
  pass "vanished panes and records without binding fields refuse instead of writing"
}

# --- skip paths and non-fatal failure ----------------------------------------

test_publish_silently_skips_non_herdr_and_remote_records() {
  local dir home fb log out rc
  dir="$TMP_ROOT/skips"; home=$(make_metadata_task "$dir" task-i backend=tmux window=tmux:win)
  log="$dir/log"; : > "$log"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: working · source: herdr-pane'

  out=$(run_publish "$home" task-i "$fb" \
    "FM_HERDR_LOG=$log" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" 2>&1)
  rc=$?
  expect_code 0 "$rc" "non-herdr: publish must be a silent no-op, got: $out"
  [ ! -s "$log" ] || fail "non-herdr: no herdr call may be made, log: $(cat "$log")"

  home=$(make_metadata_task "$dir" task-j remote_host=ops@example.com)
  : > "$log"
  out=$(run_publish "$home" task-j "$fb" \
    "FM_HERDR_LOG=$log" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" 2>&1)
  rc=$?
  expect_code 0 "$rc" "remote: publish must be a silent no-op, got: $out"
  [ ! -s "$log" ] || fail "remote: a remote-hosted pane must not be written locally, log: $(cat "$log")"
  pass "non-Herdr and remote-hosted records are silent no-ops"
}

test_publish_failure_is_a_contained_one_line_diagnostic() {
  local dir home fb log resp out rc
  dir="$TMP_ROOT/failure"; home=$(make_metadata_task "$dir" task-k)
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  printf '%s\n' 'server error' > "$resp/2.err"
  printf '%s\n' 1 > "$resp/2.exit"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: working · source: herdr-pane'

  out=$(run_publish "$home" task-k "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" 2>&1)
  rc=$?
  expect_code 1 "$rc" "failure: the entry must report the failure, got: $out"
  assert_contains "$out" 'non-fatal' \
    "failure: the diagnostic must say the failure is non-fatal"
  assert_contains "$out" 'task-k' \
    "failure: the diagnostic must name the task"

  # The non-fatal contract at the call sites is `|| true` / detached dispatch:
  # prove a caller-style wrapper survives the same failure with exit 0.
  out=$(run_publish "$home" task-k "$fb" \
    "FM_HERDR_LOG=$log" "FM_HERDR_RESPONSES=$resp" \
    "FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN=$dir/crew-state" 2>/dev/null || true)
  rc=$?
  expect_code 0 "$rc" "failure: a caller-style || true wrapper must absorb the failure"
  pass "a failed metadata write is a one-line diagnostic the caller can discard"
}

# --- clear -------------------------------------------------------------------

test_clear_erases_only_firstmate_owned_values() {
  local dir home fb log resp out rc
  dir="$TMP_ROOT/clear"; home=$(make_metadata_task "$dir" task-l)
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  fb=$(make_metadata_fakebin "$dir")

  out=$(
    # The fixture env is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export PATH="$fb:$PATH" FM_HOME="$home"
    # shellcheck disable=SC2030,SC2031
    export FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp"
    # shellcheck disable=SC2030,SC2031
    export FM_BACKEND_HERDR_METADATA_NOW=1700000001
    "$ENTRY" clear task-l 2>&1
  )
  rc=$?
  expect_code 0 "$rc" "clear: should succeed, got: $out"
  assert_contains "$(cat "$log")" $'\x1f--clear-title\x1f--clear-display-agent\x1f--clear-state-labels' \
    "clear: must erase the projected title, agent, and labels"
  assert_contains "$(cat "$log")" \
    $'\x1f--clear-token\x1ffm_task\x1f--clear-token\x1ffm_wait\x1f--clear-token\x1ffm_pr\x1f--clear-token\x1ffm_report' \
    "clear: must erase exactly the four fm_ tokens"
  assert_not_contains "$(cat "$log")" $'\x1f--token\x1f' \
    "clear: a clear must never set any token value"
  assert_contains "$(cat "$log")" $'w1:p2\x1f--session\x1fhs' \
    "clear: must target the recorded pane on the recorded session"

  # A clear refused by binding must report nonzero so a caller can log it, and
  # still never write.
  : > "$log"
  printf '%s\n' "$pane_get_mismatch" > "$resp/1.out"
  out=$(
    # The fixture env is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export PATH="$fb:$PATH" FM_HOME="$home"
    # shellcheck disable=SC2030,SC2031
    export FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp"
    "$ENTRY" clear task-l 2>&1
  )
  rc=$?
  expect_code 1 "$rc" "clear: binding refusal must be reported, got: $out"
  assert_not_contains "$(cat "$log")" 'report-metadata' \
    "clear: no write may follow a failed binding check"
  pass "clear erases exactly Firstmate-owned values on the validated pane and refuses otherwise"
}

test_clear_skips_non_herdr_remote_and_absent_records() {
  local dir home log out rc
  dir="$TMP_ROOT/clear-skips"; home=$(make_metadata_task "$dir" task-m backend=tmux window=tmux:win)
  log="$dir/log"; : > "$log"
  fb=$(make_metadata_fakebin "$dir")

  out=$(
    # The fixture env is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export PATH="$fb:$PATH" FM_HOME="$home"
    "$ENTRY" clear task-m 2>&1
  )
  rc=$?
  expect_code 0 "$rc" "clear non-herdr: silent no-op, got: $out"
  [ ! -s "$log" ] || fail "clear non-herdr: no herdr call, log: $(cat "$log")"

  out=$(
    # The fixture env is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export PATH="$fb:$PATH" FM_HOME="$home"
    "$ENTRY" clear task-never-spawned 2>&1
  )
  rc=$?
  expect_code 0 "$rc" "clear absent: silent no-op, got: $out"
  pass "clear treats non-Herdr and absent records as silent no-ops"
}

# --- entry contract ----------------------------------------------------------

test_entry_rejects_bad_usage() {
  local out rc
  out=$("$ENTRY" 2>&1); rc=$?
  expect_code 2 "$rc" "usage: a missing action must exit 2"
  assert_contains "$out" 'usage:' "usage: the refusal must print usage"

  out=$("$ENTRY" frobnicate task-x 2>&1); rc=$?
  expect_code 2 "$rc" "usage: an unknown action must exit 2"

  out=$("$ENTRY" publish 2>&1); rc=$?
  expect_code 2 "$rc" "usage: a missing task id must exit 2"
  pass "the entry rejects bad usage with exit 2 and a usage line"
}

test_publish_names_crew_state_only_for_its_own_task() {
  local dir home fb log resp out
  dir="$TMP_ROOT/crewstate"; home=$(make_metadata_task "$dir" task-n)
  log="$dir/log"; resp="$dir/resp"; mkdir -p "$resp"; : > "$log"
  printf '%s\n' "$pane_get_ok" > "$resp/1.out"
  fb=$(make_metadata_fakebin "$dir")
  make_crew_state "$dir" 'state: parked · source: status-log · awaiting a decision'
  crew_log="$dir/crew.log"; : > "$crew_log"

  out=$(
    # The fixture env is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export PATH="$fb:$PATH" FM_HOME="$home"
    # shellcheck disable=SC2030,SC2031
    export FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp"
    # shellcheck disable=SC2030,SC2031
    export FM_BACKEND_HERDR_METADATA_NOW=1700000000
    # shellcheck disable=SC2030,SC2031
    export FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN="$dir/crew-state"
    # shellcheck disable=SC2030,SC2031
    export FM_CREW_STATE_LOG="$crew_log"
    "$ENTRY" publish task-n
  ) || fail "crew-state: publish should succeed: $out"
  assert_contains "$(cat "$crew_log")" 'task-n' \
    "crew-state: the projection must ask about exactly the projected task"
  out=$(cat "$crew_log")
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] \
    || fail "crew-state: exactly one state read per publish, got: $out"
  pass "each publish reads current state once, for the projected task only"
}

# --- runner ------------------------------------------------------------------

test_publish_projects_exact_fields_from_records
test_publish_clears_marker_and_pointer_when_state_has_no_wait
test_publish_marks_review_ready_and_scout_report_ready
test_publish_clips_long_intents_and_secondmate_charters
test_publish_refuses_binding_mismatch_without_writing
test_publish_refuses_gone_and_unvalidatable_panes
test_publish_silently_skips_non_herdr_and_remote_records
test_publish_failure_is_a_contained_one_line_diagnostic
test_clear_erases_only_firstmate_owned_values
test_clear_skips_non_herdr_remote_and_absent_records
test_entry_rejects_bad_usage
test_publish_names_crew_state_only_for_its_own_task

echo "ok - fm-backend-herdr-metadata: all tests passed"
