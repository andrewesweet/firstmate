#!/usr/bin/env bash
# Crew wiki slice 01 tests (simplified design): close scans and stages
# locally, drain is the only publisher, and both stay best-effort.

set -u

ROOT=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
WIKI="$ROOT/bin/fm-wiki.sh"
BRIEF="$ROOT/bin/fm-brief.sh"

TMP_ROOT=$(fm_test_tmproot fm-wiki)

# wiki_home <name>: one fake FM_HOME with config/, state/, data/, and a
# pinned HOME so nothing leaks into the developer's own home.
wiki_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/home"
  printf '%s\n' "$home"
}

# wiki_cfg <home> <role> <remote> [host]: write config/wiki.
wiki_cfg() {
  local home=$1 role=$2 remote=$3 host=${4:-}
  { [ -z "$host" ] || printf 'host=%s\n' "$host"; } > "$home/config/wiki"
  printf 'remote=%s\n' "$remote" >> "$home/config/wiki"
  printf 'role=%s\n' "$role" >> "$home/config/wiki"
}

# wiki_task <home> <task-id> [lessons-file]: stage a finished ship task.
wiki_task() {
  local home=$1 task=$2 lessons=${3:-}
  printf 'kind=ship\nharness=pi\nmodel=test-model\nproject=/tmp/proj\n' > "$home/state/$task.meta"
  printf 'done [at=1]: PR https://example.test/pull/1\n' > "$home/state/$task.status"
  mkdir -p "$home/data/$task"
  if [ -n "$lessons" ]; then
    cp "$lessons" "$home/data/$task/lessons.md"
  else
    printf '## share the retry rule\nscope: tool:no-mistakes\nclaim: rerun after fix\n\nevidence: saw it land\n' > "$home/data/$task/lessons.md"
  fi
}

# run_wiki <home> <args...>: run one wiki verb pinned to the fake home.
run_wiki() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$WIKI" "$@"
}

# wiki_bare <name>: one fresh bare remote over file://; echoes its path.
wiki_bare() {
  local bare="$TMP_ROOT/$1.git"
  git init -q --bare "$bare"
  printf '%s\n' "$bare"
}

test_absent_config_leaves_every_verb_a_silent_noop() {
  local home out
  home=$(wiki_home absent)
  out=$(run_wiki "$home" close task-x1 2>&1) || fail "close must exit 0 with no config"
  assert_equals '' "$out" "close without config prints nothing"
  out=$(run_wiki "$home" drain 2>&1) || fail "drain must exit 0 with no config"
  assert_equals '' "$out" "drain without config prints nothing"
  out=$(run_wiki "$home" brief-snippet --role contributor 2>&1) || fail "brief-snippet must exit 0 with no config"
  assert_equals '' "$out" "brief-snippet without config prints nothing"
  out=$(run_wiki "$home" drain-if-due 2>&1) || fail "drain-if-due must exit 0 with no config"
  assert_equals '' "$out" "drain-if-due without config prints nothing"
  pass "absent config/wiki leaves every verb a silent no-op"
}

test_role_off_keeps_the_feature_fully_off() {
  local home out
  home=$(wiki_home offrole)
  wiki_cfg "$home" off "file://$TMP_ROOT/offrole.git"
  wiki_task "$home" task-x1
  out=$(run_wiki "$home" close task-x1 2>&1) || fail "close must exit 0 with role=off"
  assert_equals '' "$out" "close with role=off prints nothing"
  assert_equals '0' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "an off home never queues a lesson"
  out=$(run_wiki "$home" drain 2>&1) || fail "drain must exit 0 with role=off"
  assert_equals '' "$out" "drain with role=off prints nothing"
  pass "role=off keeps the feature fully off"
}

test_brief_snippet_owns_the_lesson_schema_for_contributing_homes() {
  local home out
  home=$(wiki_home snippet)
  wiki_cfg "$home" contributor "file://$TMP_ROOT/snippet.git"
  out=$(run_wiki "$home" brief-snippet --role contributor) || fail "brief-snippet must exit 0"
  assert_contains "$out" 'lessons.md' "the schema names the lesson file"
  assert_contains "$out" 'scope:' "the schema owns the scope line"
  assert_contains "$out" 'claim:' "the schema owns the claim line"
  assert_contains "$out" 'evidence:' "the schema owns the evidence line"
  assert_contains "$out" 'nothing-to-teach:' "the schema owns the nothing-to-teach escape"
  out=$(run_wiki "$home" brief-snippet --role reader) || fail "reader snippet must exit 0"
  assert_equals '' "$out" "a reader snippet prints nothing in slice 01"
  pass "brief-snippet owns the lesson schema for contributing homes"
}

test_close_scans_and_stages_before_anything_reaches_the_outbox() {
  local home out staging
  home=$(wiki_home stage)
  wiki_cfg "$home" contributor "file://$TMP_ROOT/stage.git"
  # A clean lesson: close queues it into the outbox, never into a drainable
  # unscanned spot.
  wiki_task "$home" task-clean
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-clean) || fail "clean close must exit 0"
  assert_contains "$out" 'queued' "the close line says the lesson is queued"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a clean lesson waits in the outbox"
  for staging in "$home/state/wiki"/.capture.*; do
    assert_absent "$staging" "a clean close leaves no generated staging directory"
  done
  # A planted key: close holds it locally, and the outbox never sees it.
  wiki_task "$home" task-leak
  printf '## leaked\nscope: t\nclaim: c\nevidence: AKIAIOSFODNN7EXAMPLE is a key\n' > "$home/data/task-leak/lessons.md"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-leak 2>&1) || fail "a flagged close must still exit 0"
  assert_contains "$out" 'held' "the close line names the held outcome"
  assert_equals '1' "$(find "$home/state/wiki/held" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a flagged lesson is held locally"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a flagged lesson never reaches the outbox"
  for staging in "$home/state/wiki"/.capture.*; do
    assert_absent "$staging" "a held close leaves no generated staging directory"
  done
  # The outbox file carries the generated stamp naming its task and final verb.
  local queued
  queued=$(cat "$(find "$home/state/wiki/outbox" -name '*.md' | head -n 1)")
  assert_contains "$queued" 'wiki-task: task-clean' "the stamp names the task literally"
  assert_contains "$queued" 'wiki-final: done' "the stamp records the task's final status"
  pass "close scans and stages before anything reaches the outbox"
}

test_close_and_drain_publish_one_raw_file_with_trailers() {
  local home bare out path
  home=$(wiki_home publish)
  bare=$(wiki_bare publish)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_task "$home" task-p1
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-p1 >/dev/null || fail "close failed"
  out=$(run_wiki "$home" drain) || fail "drain must exit 0"
  assert_contains "$out" 'pushed 1 lesson' "the drain line reports the landing"
  path=$(git -C "$bare" ls-tree -r --name-only main | head -n 1)
  assert_contains "$path" 'raw/' "the lesson lands under raw/"
  assert_contains "$path" '.md' "the lesson lands as a raw markdown file"
  assert_equals '0' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a proven landing retires the outbox file"
  local body
  body=$(git -C "$bare" show "main:$path")
  assert_contains "$body" 'wiki-task: task-p1' "the raw file carries the task stamp"
  assert_contains "$body" 'wiki-final: done' "the raw file carries the final status"
  assert_contains "$body" 'wiki-home: publish-' "the raw file carries the per-home identity"
  local msg
  msg=$(git -C "$bare" log --format=%B main)
  assert_contains "$msg" 'Wiki-Task: task-p1' "the commit carries a Wiki-Task trailer"
  assert_contains "$msg" 'Wiki-Home: publish-' "the commit carries a Wiki-Home trailer"
  assert_contains "$msg" 'Wiki-Harness: pi' "the commit carries a Wiki-Harness trailer"
  pass "close and drain publish one raw file with trailers"
}

test_missing_and_nothing_to_teach_lessons_record_without_pushing() {
  local home bare out
  home=$(wiki_home nolessons)
  bare=$(wiki_bare nolessons)
  wiki_cfg "$home" contributor "file://$bare"
  printf 'kind=ship\nharness=pi\n' > "$home/state/task-empty.meta"
  printf 'done [at=1]: x\n' > "$home/state/task-empty.status"
  mkdir -p "$home/data/task-empty"
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-empty >/dev/null || fail "close failed"
  assert_contains "$(cat "$home/state/wiki/ledger.jsonl")" '"outcome":"no-lessons"' \
    "a missing lesson file records no-lessons"
  wiki_task "$home" task-nothing
  printf 'nothing-to-teach: routine work\n' > "$home/data/task-nothing/lessons.md"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-nothing) || fail "close failed"
  assert_contains "$out" 'nothing-to-teach' "the close line names the nothing-to-teach outcome"
  assert_contains "$(cat "$home/state/wiki/ledger.jsonl")" '"outcome":"nothing-to-teach"' \
    "a nothing-to-teach file is recorded locally"
  assert_equals '0' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "neither outcome queues a lesson"
  out=$(run_wiki "$home" drain) || fail "drain must exit 0"
  assert_contains "$out" 'nothing to publish' "drain reports an empty outbox"
  [ -z "$(git -C "$bare" log --format=%H main 2>/dev/null)" ] || fail "nothing was pushed"
  pass "missing and nothing-to-teach lessons record without pushing"
}

test_task_ids_are_compared_literally() {
  local home out
  home=$(wiki_home literal)
  wiki_cfg "$home" contributor "file://$TMP_ROOT/literal.git"
  # Task-A and task-a are different tasks: closing Task-A must not read
  # task-a's records or lessons, and both closes must be recorded separately.
  wiki_task "$home" Task-A
  wiki_task "$home" task-a
  printf 'nothing-to-teach: the other task\n' > "$home/data/Task-A/lessons.md"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close Task-A) || fail "close Task-A failed"
  assert_contains "$out" 'nothing-to-teach' "closing Task-A reads Task-A's lessons"
  assert_contains "$(cat "$home/state/wiki/ledger.jsonl")" '"task":"Task-A"' \
    "the ledger records Task-A verbatim"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-a) || fail "close task-a failed"
  assert_contains "$out" 'queued' "closing task-a still finds task-a's real lesson"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "task-a's lesson was not swallowed by Task-A's records"
  pass "task ids are compared literally, never case-folded or pattern-matched"
}

test_a_duplicate_close_is_a_recorded_noop() {
  local home out
  home=$(wiki_home dup)
  wiki_cfg "$home" contributor "file://$TMP_ROOT/dup.git"
  wiki_task "$home" task-dup
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-dup >/dev/null || fail "first close failed"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-dup) || fail "duplicate close must exit 0"
  assert_contains "$out" 'already recorded' "the duplicate close names its recorded outcome"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a duplicate close queues nothing new"
  assert_equals '1' "$(wc -l < "$home/state/wiki/ledger.jsonl" | tr -d ' ')" \
    "a duplicate close appends no second ledger line"
  pass "a duplicate close is a recorded no-op"
}

test_an_unreachable_remote_queues_for_a_later_drain() {
  local home bare out
  home=$(wiki_home deadlate)
  bare=$(wiki_bare deadlate)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_task "$home" task-x6
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-x6 >/dev/null || fail "close failed"
  mv "$bare" "$bare.away"
  local started finished
  started=$(date +%s)
  out=$(run_wiki "$home" drain 2>&1) || fail "a drain against a dead remote must exit 0"
  finished=$(date +%s)
  assert_contains "$out" 'still queued' "the drain line says lessons stay queued"
  [ "$((finished - started))" -le 10 ] || fail "close/drain against a dead remote returns promptly"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "the lesson waits in the outbox for a later drain"
  mv "$bare.away" "$bare"
  out=$(run_wiki "$home" drain) || fail "the recovery drain must exit 0"
  assert_contains "$out" 'pushed 1 lesson' "the later drain lands the queued lesson"
  pass "an unreachable remote queues pending and a later drain lands it"
}

test_parallel_closes_from_homes_sharing_a_basename_land_distinct_files() {
  local homes=() bare i h out total previous current
  bare=$(wiki_bare burst)
  fm_git_init_commit "$TMP_ROOT/burst-seed"
  git -C "$TMP_ROOT/burst-seed" push -q "file://$bare" main || fail "seed push failed"
  # homes[1] and homes[2] share the basename `beta` but live in different
  # directories; their per-home identities must still keep filenames distinct.
  local dir_list="$TMP_ROOT/burst-a/alpha $TMP_ROOT/burst-b/beta $TMP_ROOT/burst-c/beta"
  for h in $dir_list; do
    mkdir -p "$h/config" "$h/state" "$h/data" "$h/home"
    homes+=("$h")
    wiki_cfg "$h" contributor "file://$bare" host=bursthost
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    for h in "${homes[@]}"; do
      wiki_task "$h" "task-$i"
    done
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    for h in "${homes[@]}"; do
      ( FM_WIKI_CLOSE_DRAIN=0 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" \
          FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" \
          FM_CONFIG_OVERRIDE="$h/config" HOME="$h/home" \
          "$WIKI" close "task-$i" >/dev/null 2>&1 ) &
    done
  done
  wait
  for h in "${homes[@]}"; do
    previous=$(git -C "$bare" rev-parse main) || fail "remote main missing before drain"
    out=$(run_wiki "$h" drain 2>&1) || fail "a burst drain must exit 0"
    assert_contains "$out" 'pushed 10 lesson' "home $(basename "$(dirname "$h")") landed its 10 lessons"
    current=$(git -C "$bare" rev-parse main) || fail "remote main missing after drain"
    assert_not_equals "$previous" "$current" "each drain advances remote main"
    git -C "$bare" merge-base --is-ancestor "$previous" "$current" \
      || fail "each drain must preserve the remote's previous history"
  done
  total=$(git -C "$bare" ls-tree -r --name-only main -- raw/ | wc -l | tr -d ' ')
  assert_equals '30' "$total" "30 lessons land as 30 distinct raw files"
  assert_equals '30' "$(git -C "$bare" ls-tree -r --name-only main -- raw/ | sort -u | wc -l | tr -d ' ')" \
    "no two lessons share a raw path"
  pass "30 parallel closes from 3 homes (two sharing a basename) land 30 distinct files with no forced update"
}

test_concurrent_drains_in_one_home_never_run_together() {
  local home out holder i contender fakebin real_git pids=()
  home=$(wiki_home singleflight)
  wiki_bare singleflight >/dev/null
  wiki_cfg "$home" contributor "file://$TMP_ROOT/singleflight.git"
  wiki_task "$home" task-sf1
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-sf1 >/dev/null || fail "close failed"
  python3 - "$home/state/wiki/.drain.lock" "$home/ready" <<'PYLOCK' &
import fcntl
import pathlib
import sys
import time
with open(sys.argv[1], "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(15)
PYLOCK
  holder=$!
  for i in {1..100}; do
    [ ! -e "$home/ready" ] || break
    sleep 0.05
  done
  assert_present "$home/ready" "the independent lock holder acquired ownership"
  for i in {1..8}; do
    run_wiki "$home" drain > "$home/contender-$i" 2>&1 &
    pids+=("$!")
  done
  for contender in "${pids[@]}"; do
    wait "$contender" || fail "a contending drain must exit 0"
  done
  for i in {1..8}; do
    assert_grep 'already running' "$home/contender-$i" "all concurrent drains defer to the live owner"
  done
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' | wc -l | tr -d ' ')" \
    "the lesson stays queued while another process owns the lock"
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pids=()
  for i in {1..8}; do
    run_wiki "$home" drain > "$home/recovery-$i" 2>&1 &
    pids+=("$!")
  done
  for contender in "${pids[@]}"; do
    wait "$contender" || fail "recovery drains must exit 0"
  done
  assert_equals '1' "$(git -C "$TMP_ROOT/singleflight.git" rev-list --count main)" \
    "concurrent recovery drains publish exactly one commit"
  assert_equals '0' "$(find "$home/state/wiki/outbox" -name '*.md' | wc -l | tr -d ' ')" \
    "a killed owner releases the lock despite its empty record"
  wiki_task "$home" task-sf2
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-sf2 >/dev/null || fail "second close failed"
  fakebin=$(fm_fakebin "$home")
  real_git=$(command -v git) || fail "git unavailable"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_WIKI_GIT_HOME/git-block" ]; then
  : > "$FM_WIKI_GIT_HOME/git-ready"
  for i in {1..200}; do
    [ -e "$FM_WIKI_GIT_HOME/git-block" ] || break
    sleep 0.05
  done
fi
exec "$FM_WIKI_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  : > "$home/git-block"
  PATH="$fakebin:$PATH" FM_WIKI_GIT_HOME="$home" FM_WIKI_REAL_GIT="$real_git" \
    run_wiki "$home" drain > "$home/owner-output" 2>&1 &
  holder=$!
  for i in {1..100}; do
    [ ! -e "$home/git-ready" ] || break
    sleep 0.05
  done
  assert_present "$home/git-ready" "the live publisher reached the Git boundary"
  out=$(run_wiki "$home" drain) || fail "a competing drain must exit 0"
  assert_contains "$out" 'already running' "ownership survives acquisition and protects the live publisher"
  rm "$home/git-block"
  wait "$holder" || fail "the live publisher must exit 0"
  assert_grep 'pushed 1 lesson' "$home/owner-output" "normal drain exit also releases ownership"
  pass "concurrent drains defer to live ownership and recover after owner death"
}

test_queue_identity_ignores_lesson_body_fields() {
  local queue home out task
  for queue in outbox held; do
    home=$(wiki_home "body-$queue")
    wiki_cfg "$home" contributor "file://$TMP_ROOT/body-$queue.git"
    wiki_task "$home" Quote-B
    printf 'wiki-task: Task-A\nwiki-task: a.b\n\n## quoted fields\nclaim: treat these as evidence\n' \
      > "$home/data/Quote-B/lessons.md"
    if [ "$queue" = held ]; then
      printf 'evidence: AKIAIOSFODNN7EXAMPLE\n' >> "$home/data/Quote-B/lessons.md"
    fi
    FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close Quote-B >/dev/null 2>&1 || fail "quoting close failed"
    assert_equals '1' "$(find "$home/state/wiki/$queue" -name '*.md' | wc -l | tr -d ' ')" \
      "the quoting lesson resides in $queue"
    rm "$home/state/wiki/ledger.jsonl"
    out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close Quote-B) || fail "stamp duplicate close failed"
    assert_contains "$out" 'already recorded (queued)' "a genuine stamp still deduplicates without a ledger"
    for task in Task-A a.b a-b; do
      wiki_task "$home" "$task"
      out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close "$task") || fail "literal task close failed"
      assert_contains "$out" 'lesson queued' "body fields in $queue cannot suppress distinct task $task"
    done
  done
  pass "queue identity reads only the literal task field in the leading stamp"
}

test_failed_held_transfer_preserves_the_captured_bytes() {
  local mode home out staging file count fakebin
  for mode in missing identical different; do
    home=$(wiki_home "hold-$mode")
    wiki_cfg "$home" contributor "file://$TMP_ROOT/hold-$mode.git"
    wiki_task "$home" task-hold
    printf '## leaked\nclaim: retain evidence\nevidence: AKIAIOSFODNN7EXAMPLE\n' \
      > "$home/data/task-hold/lessons.md"
    fakebin=$(fm_fakebin "$home")
    cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
case $FM_WIKI_LINK_RESULT in
  identical) cp "$1" "$2" ;;
  different) printf 'existing different lesson\n' > "$2" ;;
esac
exit 1
SH
    chmod +x "$fakebin/ln"
    out=$(PATH="$fakebin:$PATH" FM_WIKI_LINK_RESULT="$mode" FM_WIKI_CLOSE_DRAIN=0 \
      run_wiki "$home" close task-hold 2>&1) || fail "a failed hold must remain best-effort"
    count=0
    for staging in "$home/state/wiki"/.capture.*; do
      [ -d "$staging" ] || continue
      count=$((count + 1))
      for file in "$staging"/*.md; do
        assert_contains "$out" "$file" "failure reports the retained capture path"
        tail -n 3 "$file" | cmp -s "$home/data/task-hold/lessons.md" - \
          || fail "failure preserves every captured lesson byte"
      done
    done
    if [ "$mode" = identical ]; then
      assert_equals '0' "$count" "an identical held destination permits capture retirement"
      assert_contains "$out" 'held locally' "an identical held destination counts as success"
      assert_grep '"outcome":"held"' "$home/state/wiki/ledger.jsonl" "only proven transfers record held"
    else
      assert_equals '1' "$count" "a failed or conflicting transfer retains its staging directory"
      assert_contains "$out" 'failed to hold' "failure remains actionable"
      assert_absent "$home/state/wiki/ledger.jsonl" "failed transfers do not suppress a later capture"
      if [ "$mode" = different ]; then
        assert_equals 'existing different lesson' "$(cat "$home/state/wiki/held/"*.md)" \
          "a conflicting held destination is immutable"
      fi
    fi
    assert_equals '0' "$(find "$home/state/wiki/outbox" -name '*.md' | wc -l | tr -d ' ')" \
      "held transfer outcomes never expose a secret to publication"
  done
  pass "failed held transfers preserve evidence unless an identical destination exists"
}

test_every_completed_close_retries_the_existing_queue() {
  local mode home bare attempt expected remaining
  for mode in duplicate queued missing nothing held accepted; do
    home=$(wiki_home "retry-$mode")
    bare=$(wiki_bare "retry-$mode")
    wiki_cfg "$home" contributor "file://$bare"
    wiki_task "$home" task-a
    FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-a >/dev/null || fail "initial capture failed"
    mv "$bare" "$bare.away"
    run_wiki "$home" drain >/dev/null || fail "outage drain failed"
    mv "$bare.away" "$bare"
    expected=1
    case $mode in
      duplicate) set -- task-a ;;
      queued) rm "$home/state/wiki/ledger.jsonl"; set -- task-a ;;
      *)
        wiki_task "$home" task-b
        set -- task-b
        case $mode in
          missing) rm "$home/data/task-b/lessons.md" ;;
          nothing) printf 'nothing-to-teach: routine\n' > "$home/data/task-b/lessons.md" ;;
          held) printf 'evidence: AKIAIOSFODNN7EXAMPLE\n' > "$home/data/task-b/lessons.md" ;;
          accepted) expected=2 ;;
        esac
        ;;
    esac
    run_wiki "$home" close "$@" >/dev/null 2>&1 || fail "$mode close failed"
    remaining=1
    for attempt in {1..200}; do
      remaining=$(find "$home/state/wiki/outbox" -name '*.md' | wc -l | tr -d ' ')
      [ "$remaining" != 0 ] || break
      sleep 0.05
    done
    assert_equals '0' "$remaining" "$mode close must retry the older queue without a watcher tick"
    assert_equals "$expected" "$(git -C "$bare" ls-tree -r --name-only main -- raw/ | wc -l | tr -d ' ')" \
      "$mode close publishes all clean lessons after remote recovery"
  done
  pass "every completed close hands the existing queue to the guarded drain"
}

test_watcher_tick_paces_itself_by_its_stamp() {
  local home out
  home=$(wiki_home tick)
  wiki_bare tick >/dev/null
  wiki_cfg "$home" contributor "file://$TMP_ROOT/tick.git"
  wiki_task "$home" task-t1
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-t1 >/dev/null || fail "close failed"
  out=$(run_wiki "$home" drain-if-due) || fail "drain-if-due must exit 0"
  assert_contains "$out" 'pushed 1 lesson' "a due tick drains"
  out=$(run_wiki "$home" drain-if-due) || fail "a fresh-stamp tick must exit 0"
  assert_equals '' "$out" "a fresh stamp keeps the next tick a no-op"
  python3 - "$home/state/wiki/.last-drain" <<'PYTIME'
import os
import sys
os.utime(sys.argv[1], (1577836800, 1577836800))
PYTIME
  out=$(run_wiki "$home" drain-if-due) || fail "an aged-stamp tick must exit 0"
  assert_contains "$out" 'nothing to publish' "an aged stamp lets the next tick run"
  pass "the watcher tick paces itself by its stamp"
}

test_a_completed_task_stamps_its_final_status_not_none() {
  local home bare out queued
  home=$(wiki_home finalverb)
  bare=$(wiki_bare finalverb)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_task "$home" task-final
  # Close reads the task's final status line itself; teardown calls it in the
  # same window (after the final outcome is read, before the file is retired),
  # so a completed task's published lesson records `done`, not `none`.
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-final >/dev/null || fail "close failed"
  queued=$(cat "$(find "$home/state/wiki/outbox" -name '*.md' | head -n 1)")
  assert_contains "$queued" 'wiki-final: done' "a completed task's final status is recorded, not none"
  run_wiki "$home" drain >/dev/null || fail "drain failed"
  out=$(git -C "$bare" show "main:$(git -C "$bare" ls-tree -r --name-only main | head -n 1)")
  assert_contains "$out" 'wiki-final: done' "the published lesson records the final status"
  pass "a completed task's final status is recorded, not none"
}

test_close_stays_idempotent_across_repeated_calls() {
  local home out
  home=$(wiki_home idem)
  wiki_bare idem >/dev/null
  wiki_cfg "$home" contributor "file://$TMP_ROOT/idem.git"
  wiki_task "$home" task-idem
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-idem >/dev/null || fail "first close failed"
  run_wiki "$home" drain >/dev/null || fail "drain failed"
  # After landing, the ledger still names the task: a later close is a no-op,
  # even with the lessons file still present.
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-idem) || fail "a post-landing close must exit 0"
  assert_contains "$out" 'already recorded' "the post-landing close names its recorded outcome"
  assert_equals '0' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a post-landing close queues nothing new"
  pass "close stays idempotent across repeated calls"
}

test_dod_insertion_follows_the_opt_in() {
  local home brief out
  # No config: no wiki step in any brief.
  home=$(wiki_home brief-off)
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$BRIEF" brief-off-x1 some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "the ship brief scaffold failed without config/wiki"
  brief="$home/data/brief-off-x1/brief.md"
  assert_grep '# Definition of done' "$brief" "the ship brief keeps its DoD"
  if grep -q 'Crew wiki' "$brief"; then
    fail "a home without config/wiki must not get a wiki step"
  fi
  # Contributor config: the step lands before the final status line.
  wiki_cfg "$home" contributor "file://$TMP_ROOT/brief-opt.git"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$BRIEF" brief-on-x1 some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "the ship brief scaffold failed with config/wiki"
  brief="$home/data/brief-on-x1/brief.md"
  assert_grep '## Crew wiki' "$brief" "an opted-in ship brief carries the wiki step"
  assert_grep 'brief-on-x1/lessons.md' "$brief" "the wiki step names this task's lesson file"
  assert_grep 'nothing-to-teach:' "$brief" "the brief carries the schema"
  local wiki_line final_line
  wiki_line=$(grep -n '## Crew wiki' "$brief" | cut -d: -f1)
  final_line=$(grep -n 'Append `done \[at=<epoch>\]: PR ' "$brief" | head -1 | cut -d: -f1)
  [ -n "$final_line" ] && [ "$wiki_line" -lt "$final_line" ] \
    || fail "the wiki step must sit before the final status line"
  # A default home (unset FM_HOME) still resolves the opt-in from ITS OWN
  # config directory, not the repository's.
  local defhome="$TMP_ROOT/defhome"
  mkdir -p "$defhome/config" "$defhome/data" "$defhome/state" "$defhome/home"
  wiki_cfg "$defhome" contributor "file://$TMP_ROOT/brief-def.git"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME='' FM_STATE_OVERRIDE="$defhome/state" \
    FM_DATA_OVERRIDE="$defhome/data" FM_CONFIG_OVERRIDE="$defhome/config" HOME="$defhome/home" \
    "$BRIEF" brief-def-x1 some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "the default-home brief scaffold failed"
  brief="$defhome/data/brief-def-x1/brief.md"
  assert_grep '## Crew wiki' "$brief" "a default-home brief resolves the opt-in from its own config"
  # The scout DoD gets the same insertion.
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$BRIEF" brief-scout-x1 some-proj --scout >/dev/null 2>&1 \
    || fail "the scout brief scaffold failed with config/wiki"
  brief="$home/data/brief-scout-x1/brief.md"
  assert_grep '## Crew wiki' "$brief" "an opted-in scout brief carries the wiki step"
  assert_grep 'brief-scout-x1/lessons.md' "$brief" "the scout wiki step names this task's lesson file"
  # A reader home gets no contribution step in slice 01.
  wiki_cfg "$home" reader "file://$TMP_ROOT/brief-read.git"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$BRIEF" brief-read-x1 some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "the ship brief scaffold failed for a reader home"
  brief="$home/data/brief-read-x1/brief.md"
  if grep -q 'Crew wiki' "$brief"; then
    fail "a reader home must not get a contribution step in slice 01"
  fi
  pass "brief insertion follows the config/wiki opt-in for ships and scouts"
}

test_absent_config_leaves_every_verb_a_silent_noop
test_role_off_keeps_the_feature_fully_off
test_brief_snippet_owns_the_lesson_schema_for_contributing_homes
test_close_scans_and_stages_before_anything_reaches_the_outbox
test_close_and_drain_publish_one_raw_file_with_trailers
test_missing_and_nothing_to_teach_lessons_record_without_pushing
test_task_ids_are_compared_literally
test_a_duplicate_close_is_a_recorded_noop
test_an_unreachable_remote_queues_for_a_later_drain
test_parallel_closes_from_homes_sharing_a_basename_land_distinct_files
test_concurrent_drains_in_one_home_never_run_together
test_queue_identity_ignores_lesson_body_fields
test_failed_held_transfer_preserves_the_captured_bytes
test_every_completed_close_retries_the_existing_queue
test_watcher_tick_paces_itself_by_its_stamp
test_a_completed_task_stamps_its_final_status_not_none
test_close_stays_idempotent_across_repeated_calls
test_dod_insertion_follows_the_opt_in
