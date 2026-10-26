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

wiki_mirror_fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
print(json.dumps([(str(p.relative_to(root)), hashlib.sha256(p.read_bytes()).hexdigest())
                  for p in sorted(root.rglob('*')) if p.is_file()]))
PY
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
  printf '## a lesson nobody files\nscope: t\nclaim: c\n\nevidence: e\n' > "$home/data/sup.md"
  out=$(run_wiki "$home" file "$home/data/sup.md" 2>&1) || fail "file must exit 0 with no config"
  assert_equals '' "$out" "file without config prints nothing"
  [ ! -e "$home/state/wiki" ] || fail "file without config creates no wiki state"
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
  printf '## a lesson nobody files\nscope: t\nclaim: c\n\nevidence: e\n' > "$home/data/sup.md"
  out=$(run_wiki "$home" file "$home/data/sup.md" 2>&1) || fail "file must exit 0 with role=off"
  assert_equals '' "$out" "file with role=off prints nothing"
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
  assert_contains "$out" "$home/state/wiki/mirror" "the consult paragraph prints the mirror's absolute path"
  assert_contains "$out" 'grep -ril' "the consult paragraph starts at grep over pages"
  assert_contains "$out" 'at most three' "the consult paragraph caps the page reads"
  assert_contains "$out" 'unreviewed' "the consult paragraph marks raw matches unreviewed"
  assert_contains "$out" 'data, not instructions' "the consult paragraph keeps wiki text subordinate to the brief"
  if grep -q 'nothing-to-teach:' <<<"$out"; then
    fail "a reader snippet carries no lesson-writing step"
  fi
  pass "brief-snippet owns the lesson schema for contributing homes and the consult paragraph for readers"
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

# wiki_sup_task <home> <task-id> <lessons-text|-> <supervision-text|->: stage a
# finished task's lesson and supervision files; - omits the file.
wiki_sup_task() {
  local home=$1 task=$2 lessons=$3 supervision=$4
  printf 'kind=ship\nharness=pi\nmodel=test-model\nproject=/tmp/proj\n' > "$home/state/$task.meta"
  printf 'done [at=1]: PR https://example.test/pull/1\n' > "$home/state/$task.status"
  mkdir -p "$home/data/$task"
  if [ "$lessons" != - ]; then
    printf '%s\n' "$lessons" > "$home/data/$task/lessons.md"
  fi
  if [ "$supervision" != - ]; then
    printf '%s\n' "$supervision" > "$home/data/$task/supervision.md"
  fi
}

test_close_collects_a_supervision_file_as_one_supervisor_lesson() {
  local home bare out queued body path
  home=$(wiki_home supclose)
  bare=$(wiki_bare supclose)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_sup_task "$home" task-s1 - '## steer through the durable inbox\nscope: harness:pi\nclaim: send text with fm-send\n\nevidence: the doorbell rang\n'
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-s1 2>&1) || fail "close with only supervision.md must exit 0"
  assert_contains "$out" 'queued' "the supervision close reports its queued lesson"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a task with only supervision.md queues exactly one lesson"
  queued=$(cat "$(find "$home/state/wiki/outbox" -name '*.md' | head -n 1)")
  assert_contains "$queued" 'wiki-role: supervisor' "the stamp marks a supervisor lesson"
  assert_contains "$queued" 'wiki-kind: supervision' "the stamp kinds the lesson as supervision"
  assert_contains "$queued" 'wiki-agent: firstmate' "the stamp names the supervisor agent"
  assert_contains "$queued" 'wiki-task: task-s1' "the stamp names the supervised task"
  assert_contains "$queued" 'wiki-harness: pi' "the stamp keeps the task's harness"
  assert_grep '"outcome":"lesson"' "$home/state/wiki/ledger.jsonl" "the ledger records the capture"
  assert_grep '"supervisor":"lesson"' "$home/state/wiki/ledger.jsonl" "the ledger names the supervision capture"
  out=$(run_wiki "$home" drain) || fail "drain must exit 0"
  assert_contains "$out" 'pushed 1 lesson' "the drain lands the supervision lesson"
  path=$(git -C "$bare" ls-tree -r --name-only main | head -n 1)
  body=$(git -C "$bare" show "main:$path")
  assert_contains "$body" 'wiki-role: supervisor' "the raw file keeps the supervisor stamp"
  assert_contains "$body" 'evidence: the doorbell rang' "the raw file keeps the lesson body"
  pass "close collects a supervision.md as one supervisor-stamped lesson"
}

test_file_verb_scans_holds_and_stays_idempotent() {
  local home bare out path body sup leak
  home=$(wiki_home supfile)
  bare=$(wiki_bare supfile)
  wiki_cfg "$home" contributor "file://$bare"
  mkdir -p "$home/data"
  sup="$home/data/wiki-supervision/20261025T000000Z.md"
  mkdir -p "$home/data/wiki-supervision"
  printf '## recovery recipe\nscope: harness:claude\nclaim: resume the session\n\nevidence: the window came back\n' > "$sup"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" file "$sup" 2>&1) || fail "file must exit 0"
  assert_contains "$out" 'queued' "file reports its queued lesson"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "file queues exactly one lesson"
  assert_grep '"supervisor":"lesson"' "$home/state/wiki/ledger.jsonl" "the ledger records the filed lesson"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" file "$sup" 2>&1) || fail "a repeated file must exit 0"
  assert_contains "$out" 'already recorded' "a repeated file names its recorded outcome"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a repeated file queues nothing new"
  leak="$home/data/wiki-supervision/leak.md"
  printf 'evidence: AKIAIOSFODNN7EXAMPLE is a key\n' > "$leak"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" file "$leak" 2>&1) || fail "a flagged file must still exit 0"
  assert_contains "$out" 'held' "file names the held outcome"
  case $out in *queued*) fail "a held file must never report queued" ;; esac
  assert_equals '1' "$(find "$home/state/wiki/held" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a flagged supervision file is held locally"
  assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a flagged supervision file never reaches the outbox"
  out=$(run_wiki "$home" drain) || fail "drain must exit 0"
  assert_contains "$out" 'pushed 1 lesson' "the drain lands the filed lesson"
  path=$(git -C "$bare" ls-tree -r --name-only main | head -n 1)
  body=$(git -C "$bare" show "main:$path")
  assert_contains "$body" 'wiki-role: supervisor' "the raw file keeps the supervisor stamp"
  assert_contains "$body" 'wiki-task: session' "a filed lesson stamps the session task id"
  assert_contains "$body" 'wiki-agent: firstmate' "the raw file names the supervisor agent"
  pass "file scans, holds planted keys, and is idempotent per content"
}

test_close_records_supervisor_none_without_a_supervision_file() {
  local home bare
  home=$(wiki_home supnone)
  bare=$(wiki_bare supnone)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_task "$home" task-s2
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-s2 >/dev/null || fail "close failed"
  assert_grep '"supervisor":"none"' "$home/state/wiki/ledger.jsonl" \
    "a task with no supervision file records supervisor none"
  pass "close records supervisor none without a supervision file"
}

test_close_collects_worker_and_supervision_lessons_together() {
  local home bare out queued
  home=$(wiki_home supboth)
  bare=$(wiki_bare supboth)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_sup_task "$home" task-s3 \
    '## share the retry rule\nscope: tool:no-mistakes\nclaim: rerun after fix\n\nevidence: saw it land\n' \
    '## steer early\nscope: harness:pi\nclaim: brief before spawn\n\nevidence: less rework\n'
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-s3 2>&1) || fail "close must exit 0"
  assert_equals '2' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "a close with both files queues both lessons"
  assert_grep '"files":2' "$home/state/wiki/ledger.jsonl" "the ledger counts both captured files"
  assert_grep '"supervisor":"lesson"' "$home/state/wiki/ledger.jsonl" "the ledger names the supervision capture"
  assert_equals '1' "$(grep -l '^wiki-role: supervisor$' "$home/state/wiki/outbox"/*.md | wc -l | tr -d ' ')" \
    "exactly one queued file is the supervision half"
  # A nothing-to-teach worker lesson does not block the supervision half.
  wiki_sup_task "$home" task-s4 'nothing-to-teach: routine work\n' \
    '## steer with questions\nscope: intake\nclaim: ask one question\n\nevidence: clearer specs\n'
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-s4 2>&1) || fail "close task-s4 must exit 0"
  assert_contains "$out" 'supervision lesson queued' "the supervision half reports itself"
  assert_equals '3' "$(find "$home/state/wiki/outbox" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
    "the nothing-to-teach close queues only the supervision lesson"
  local s4
  s4=$(grep -rl '^wiki-task: task-s4$' "$home/state/wiki/outbox" 2>/dev/null | head -n 1)
  [ -n "$s4" ] || fail "the task-s4 close queues its supervision lesson"
  grep -q '^wiki-kind: supervision$' "$s4" || fail "the task-s4 lesson is stamped as supervision"
  assert_grep '"outcome":"lesson"' "$home/state/wiki/ledger.jsonl" "the close still records a lesson"
  pass "close collects worker and supervision lessons through one ledger line"
}

test_secondmate_home_stamps_its_own_supervisor_agent() {
  local home out queued
  home=$(wiki_home supmate)
  wiki_cfg "$home" contributor "file://$TMP_ROOT/supmate.git"
  printf 'selfimprove\n' > "$home/.fm-secondmate-home"
  mkdir -p "$home/data"
  printf '## charter note\nscope: routing\nclaim: route by scope\n\nevidence: fewer misroutes\n' > "$home/data/sup.md"
  out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" file "$home/data/sup.md" 2>&1) || fail "file must exit 0"
  assert_contains "$out" 'queued' "the secondmate home files its lesson"
  queued=$(cat "$(find "$home/state/wiki/outbox" -name '*.md' | head -n 1)")
  assert_contains "$queued" 'wiki-agent: secondmate:selfimprove' \
    "a secondmate home stamps its own supervisor agent"
  pass "a secondmate home stamps secondmate:<id> as the supervisor agent"
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
    assert_grep '"files":1' "$home/state/wiki/ledger.jsonl" \
      "a genuine stamp still deduplicates without a ledger"
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
    for ((attempt = 1; attempt <= 200; attempt++)); do
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

test_partial_close_retries_only_the_missing_contribution() {
  local mode home bare out fakebin real_cat
  real_cat=$(command -v cat) || fail "cat unavailable"
  for mode in lesson held; do
    home=$(wiki_home "partial-$mode")
    bare=$(wiki_bare "partial-$mode")
    wiki_cfg "$home" contributor "file://$bare"
    wiki_task "$home" task-partial
    printf '## supervision\nclaim: preserve both contributions\n' > "$home/data/task-partial/supervision.md"
    if [ "$mode" = held ]; then
      printf 'evidence: AKIAIOSFODNN7EXAMPLE\n' >> "$home/data/task-partial/lessons.md"
    fi
    fakebin=$(fm_fakebin "$home")
    cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$FM_WIKI_BLOCKED_SOURCE" ]; then exit 1; fi
exec "$FM_WIKI_REAL_CAT" "$@"
SH
    chmod +x "$fakebin/cat"
    out=$(PATH="$fakebin:$PATH" FM_WIKI_REAL_CAT="$real_cat" \
      FM_WIKI_BLOCKED_SOURCE="$home/data/task-partial/supervision.md" FM_WIKI_CLOSE_DRAIN=0 \
      run_wiki "$home" close task-partial 2>&1) || fail "partial capture must be best effort"
    assert_contains "$out" 'failed to stamp' "the supervisor failure is observable"
    case $out in *'recorded for'*|*'lesson queued'*) fail "partial capture must not announce completion" ;; esac
    assert_grep '"supervisor":"failed"' "$home/state/wiki/ledger.jsonl" "partial progress remains retryable"
    run_wiki "$home" drain >/dev/null || fail "an independent drain failed"
    out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-partial 2>&1) || fail "retry failed"
    assert_contains "$out" 'supervision lesson queued' "retry captures the missing supervisor contribution"
    assert_contains "$(tail -n 1 "$home/state/wiki/ledger.jsonl")" '"files":2' "completion counts both contributions"
    run_wiki "$home" drain >/dev/null || fail "completion drain failed"
    if [ "$mode" = lesson ]; then
      assert_equals '2' "$(git -C "$bare" ls-tree -r --name-only main -- raw/ | wc -l | tr -d ' ')" \
        "a published worker is not duplicated by the retry"
    else
      assert_equals '1' "$(git -C "$bare" ls-tree -r --name-only main -- raw/ | wc -l | tr -d ' ')" \
        "only the supervisor lesson is published"
      assert_equals '1' "$(find "$home/state/wiki/held" -name '*.md' | wc -l | tr -d ' ')" \
        "the held worker is not duplicated by the retry"
    fi
  done
  pass "partial closes retry missing contributions even after publication"
}

test_queued_contributions_are_deduplicated_separately() {
  local role queue home queued
  for role in worker supervisor; do
    for queue in outbox held; do
      home=$(wiki_home "queued-$role-$queue")
      wiki_cfg "$home" contributor ''
      wiki_task "$home" task-retry
      printf '## supervision\nclaim: capture independently\n' > "$home/data/task-retry/supervision.md"
      if [ "$queue" = held ]; then
        printf 'evidence: AKIAIOSFODNN7EXAMPLE\n' >> "$home/data/task-retry/lessons.md"
        printf 'evidence: AKIAIOSFODNN7EXAMPLE\n' >> "$home/data/task-retry/supervision.md"
      fi
      FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-retry >/dev/null 2>&1 || fail "initial close failed"
      rm "$home/state/wiki/ledger.jsonl"
      for queued in "$home/state/wiki/$queue/"*.md; do
        if grep -q '^wiki-role: supervisor$' "$queued"; then
          [ "$role" = worker ] || rm "$queued"
        else
          [ "$role" = supervisor ] || rm "$queued"
        fi
      done
      FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-retry >/dev/null 2>&1 || fail "retry failed"
      assert_equals '2' "$(find "$home/state/wiki/$queue" -name '*.md' | wc -l | tr -d ' ')" \
        "an existing contribution cannot suppress its missing sibling"
      assert_grep '"files":2' "$home/state/wiki/ledger.jsonl" "recovered completion counts both files"
    done
  done
  pass "queued worker and supervisor contributions have distinct identities"
}

test_standalone_and_task_identities_do_not_collide() {
  local order home path hash
  for order in file-first task-first; do
    home=$(wiki_home "identity-$order")
    wiki_cfg "$home" contributor ''
    path="$home/data/standalone.md"
    printf '## standalone\nclaim: keep identities separate\n' > "$path"
    hash=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest()[:12])' "$path")
    wiki_task "$home" "file-$hash"
    wiki_sup_task "$home" session - '## task supervisor'
    if [ "$order" = file-first ]; then
      FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" file "$path" >/dev/null || fail "file failed"
    fi
    FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close "file-$hash" >/dev/null || fail "digest-named task failed"
    FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close session >/dev/null || fail "session task failed"
    FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" file "$path" >/dev/null || fail "file failed"
    assert_equals '3' "$(find "$home/state/wiki/outbox" -name '*.md' | wc -l | tr -d ' ')" \
      "standalone content and both valid task identities remain independent"
  done
  pass "standalone identities cannot collide with session or digest-named tasks"
}

test_close_reports_completed_capture_outcomes() {
  local worker supervisor home out expected files
  for worker in missing nothing lesson held; do
    for supervisor in lesson held; do
      home=$(wiki_home "report-$worker-$supervisor")
      wiki_cfg "$home" contributor ''
      wiki_task "$home" task-report
      case $worker in
        missing) rm "$home/data/task-report/lessons.md" ;;
        nothing) printf 'nothing-to-teach: routine\n' > "$home/data/task-report/lessons.md" ;;
        held) printf 'evidence: AKIAIOSFODNN7EXAMPLE\n' > "$home/data/task-report/lessons.md" ;;
      esac
      printf '## supervision\nclaim: report saved outcomes\n' > "$home/data/task-report/supervision.md"
      if [ "$supervisor" = held ]; then
        printf 'evidence: AKIAIOSFODNN7EXAMPLE\n' >> "$home/data/task-report/supervision.md"
      fi
      case "$worker:$supervisor" in
        lesson:*|*:lesson) expected=lesson ;;
        *) expected=held ;;
      esac
      case $worker in lesson|held) files=2 ;; *) files=1 ;; esac
      out=$(FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-report 2>&1) || fail "close failed"
      case $out in *'no-lessons recorded'*|*'nothing-to-teach recorded'*) fail "report ignores captured supervision" ;; esac
      if [ "$expected" = held ]; then
        assert_contains "$out" 'held recorded' "a held-only close reports held"
        case $out in *queued*) fail "held-only capture must never report queued" ;; esac
      else
        assert_contains "$out" 'lesson queued' "a clean contribution reports a lesson"
      fi
      python3 - "$home/state/wiki/ledger.jsonl" "$expected" "$supervisor" "$files" <<'PY' || fail "ledger must match completed captures"
import json, sys
record = json.loads(open(sys.argv[1]).read())
assert record["outcome"] == sys.argv[2]
assert record["supervisor"] == sys.argv[3]
assert record["files"] == int(sys.argv[4])
PY
    done
  done
  pass "close reports and records aggregate completed capture outcomes"
}

test_refiling_retries_publication_without_a_watcher() {
  local mode home bare path remaining attempt
  for mode in recorded queued held; do
    home=$(wiki_home "refile-$mode")
    bare=$(wiki_bare "refile-$mode")
    wiki_cfg "$home" contributor "file://$bare"
    path="$home/data/standalone.md"
    printf '## standalone\nclaim: retry publication\n' > "$path"
    FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" file "$path" >/dev/null || fail "initial file failed"
    mv "$bare" "$bare.away"
    run_wiki "$home" drain >/dev/null || fail "outage drain failed"
    mv "$bare.away" "$bare"
    if [ "$mode" = queued ]; then rm "$home/state/wiki/ledger.jsonl"; fi
    if [ "$mode" = held ]; then
      path="$home/data/held.md"
      printf 'evidence: AKIAIOSFODNN7EXAMPLE\n' > "$path"
      FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" file "$path" >/dev/null 2>&1 || fail "held file failed"
    fi
    run_wiki "$home" file "$path" >/dev/null 2>&1 || fail "refile failed"
    remaining=1
    for ((attempt = 1; attempt <= 200; attempt++)); do
      remaining=$(find "$home/state/wiki/outbox" -name '*.md' | wc -l | tr -d ' ')
      [ "$remaining" != 0 ] || break
      sleep 0.05
    done
    assert_equals '0' "$remaining" "refiling $mode content retries the existing queue"
    assert_equals '1' "$(git -C "$bare" ls-tree -r --name-only main -- raw/ | wc -l | tr -d ' ')" \
      "refiling publishes exactly the original clean lesson"
  done
  pass "refiling recorded, queued, or held content retries publication without a watcher"
}

test_lesson_copies_remain_owner_only_under_a_permissive_umask() {
  local home bare fakebin task
  home=$(wiki_home permissions)
  bare=$(wiki_bare permissions)
  wiki_cfg "$home" contributor "file://$bare"
  mkdir -p "$home/state/wiki/outbox" "$home/state/wiki/held"
  chmod 755 "$home/state/wiki" "$home/state/wiki/outbox" "$home/state/wiki/held"
  for task in task-clean task-held task-retained; do
    wiki_task "$home" "$task"
    if [ "$task" != task-clean ]; then
      printf '## private evidence\nclaim: retain locally\nevidence: AKIAIOSFODNN7EXAMPLE\n' \
        > "$home/data/$task/lessons.md"
    fi
    chmod 600 "$home/data/$task/lessons.md"
  done
  (umask 022; FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-clean >/dev/null) \
    || fail "clean capture failed"
  (umask 022; FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-held >/dev/null 2>&1) \
    || fail "held capture failed"
  fakebin=$(fm_fakebin "$home")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/ln"
  chmod +x "$fakebin/ln"
  (umask 022; PATH="$fakebin:$PATH" FM_WIKI_CLOSE_DRAIN=0 \
    run_wiki "$home" close task-retained >/dev/null 2>&1) || fail "retained capture failed"
  python3 - "$home/state/wiki" <<'PYPERMS' || fail "lesson captures must remain owner-only"
import pathlib
import stat
import sys
root = pathlib.Path(sys.argv[1])
assert len(list((root / "outbox").glob("*.md"))) == 1
assert len(list((root / "held").glob("*.md"))) == 1
captures = list(root.glob(".capture.*"))
assert len(captures) == 1
assert len(list(captures[0].glob("*.md"))) == 1
for path in [root, root / "outbox", root / "held", *captures]:
    assert stat.S_IMODE(path.stat().st_mode) == 0o700, str(path)
for path in root.rglob("*.md"):
    assert stat.S_IMODE(path.stat().st_mode) == 0o600, str(path)
PYPERMS
  git clone -q "file://$bare" "$home/state/wiki/repo" 2>/dev/null || fail "fixture clone failed"
  chmod 755 "$home/state/wiki/repo"
  (umask 022; run_wiki "$home" drain >/dev/null) || fail "private clone drain failed"
  python3 - "$home/state/wiki" <<'PYPUBLISH' || fail "publication must preserve local privacy"
import pathlib
import stat
import sys
root = pathlib.Path(sys.argv[1])
assert stat.S_IMODE((root / "repo").stat().st_mode) == 0o700
raw = list((root / "repo" / "raw").rglob("*.md"))
assert len(raw) == 1
for path in root.rglob("*.md"):
    assert stat.S_IMODE(path.stat().st_mode) == 0o600, str(path)
PYPUBLISH
  pass "queued, held, retained, and cloned lessons stay owner-only under umask 022"
}

test_git_calls_are_bounded_without_timeout_or_perl() {
  local fakebin real_git tool operation home bare out started elapsed
  fakebin="$TMP_ROOT/bounded-bin"
  mkdir -p "$fakebin"
  real_git=$(command -v git) || fail "git unavailable"
  for tool in bash python3 date uname tr sed awk head tail mkdir chmod basename dirname \
    mktemp cp rm find wc cat sleep mv ln cmp cut grep; do
    ln -s "$(command -v "$tool")" "$fakebin/$tool" || fail "cannot expose test tool $tool"
  done
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_WIKI_STALL_OPERATION" ]; then
    printf '%s\n' "$$" > "$FM_WIKI_STALL_MARKER"
    exec sleep 15
  fi
done
exec "$FM_WIKI_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  for tool in timeout gtimeout perl; do
    if PATH="$fakebin" command -v "$tool" >/dev/null 2>&1; then
      fail "$tool must be absent from the bounded-Git fixture"
    fi
  done
  for operation in clone fetch push; do
    home=$(wiki_home "bounded-$operation")
    bare=$(wiki_bare "bounded-$operation")
    wiki_cfg "$home" contributor "file://$bare"
    wiki_task "$home" task-bounded
    FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-bounded >/dev/null || fail "bounded capture failed"
    if [ "$operation" != clone ]; then
      git clone -q "file://$bare" "$home/state/wiki/repo" 2>/dev/null || fail "fixture clone failed"
    fi
    started=$(date +%s)
    out=$(PATH="$fakebin" FM_TIMEOUT_MECHANISM_OVERRIDE='' FM_WIKI_DRAIN_CAP=3 \
      FM_WIKI_REAL_GIT="$real_git" FM_WIKI_STALL_OPERATION="$operation" \
      FM_WIKI_STALL_MARKER="$home/stalled" run_wiki "$home" drain 2>&1) \
      || fail "a bounded $operation must remain best-effort"
    elapsed=$(( $(date +%s) - started ))
    assert_present "$home/stalled" "the drain reached the stalled $operation boundary"
    [ "$elapsed" -le 7 ] || fail "stalled $operation exceeded its drain budget ($elapsed seconds)"
    assert_contains "$out" 'still queued' "a timed-out $operation leaves the lesson queued"
    assert_equals '1' "$(find "$home/state/wiki/outbox" -name '*.md' | wc -l | tr -d ' ')" \
      "a timed-out $operation cannot retire the lesson"
    out=$(run_wiki "$home" drain) || fail "recovery from stalled $operation failed"
    assert_contains "$out" 'pushed 1 lesson' "publication recovers after the $operation timeout releases ownership"
  done
  pass "clone, fetch, and push stay bounded without timeout or Perl and recover afterward"
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
  # A reader home gets the consult paragraph, and no contribution step.
  wiki_cfg "$home" reader "file://$TMP_ROOT/brief-read.git"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$BRIEF" brief-read-x1 some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "the ship brief scaffold failed for a reader home"
  brief="$home/data/brief-read-x1/brief.md"
  assert_grep '## Crew wiki' "$brief" "an opted-in reader brief carries the consult paragraph"
  assert_grep 'state/wiki/mirror' "$brief" "the reader brief prints the mirror path"
  if grep -q "This task's lesson file" "$brief"; then
    fail "a reader brief must not name a lesson file"
  fi
  if grep -q 'nothing-to-teach:' "$brief"; then
    fail "a reader brief must not carry the lesson-writing schema"
  fi
  # A contributor home gets both the lesson step and the consult paragraph.
  wiki_cfg "$home" contributor "file://$TMP_ROOT/brief-opt.git"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$BRIEF" brief-both-x1 some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "the ship brief scaffold failed for the combined check"
  brief="$home/data/brief-both-x1/brief.md"
  assert_grep 'brief-both-x1/lessons.md' "$brief" "the contributor brief still names this task's lesson file"
  assert_grep 'state/wiki/mirror' "$brief" "the contributor brief also prints the mirror path"
  pass "brief insertion follows the config/wiki opt-in for ships and scouts"
}

test_absent_config_leaves_every_verb_a_silent_noop
test_role_off_keeps_the_feature_fully_off
test_brief_snippet_owns_the_lesson_schema_for_contributing_homes
test_close_scans_and_stages_before_anything_reaches_the_outbox
test_close_and_drain_publish_one_raw_file_with_trailers
test_missing_and_nothing_to_teach_lessons_record_without_pushing
test_close_collects_a_supervision_file_as_one_supervisor_lesson
test_file_verb_scans_holds_and_stays_idempotent
test_close_records_supervisor_none_without_a_supervision_file
test_close_collects_worker_and_supervision_lessons_together
test_secondmate_home_stamps_its_own_supervisor_agent
test_task_ids_are_compared_literally
test_a_duplicate_close_is_a_recorded_noop
test_an_unreachable_remote_queues_for_a_later_drain
test_parallel_closes_from_homes_sharing_a_basename_land_distinct_files
test_concurrent_drains_in_one_home_never_run_together
test_queue_identity_ignores_lesson_body_fields
test_failed_held_transfer_preserves_the_captured_bytes
test_every_completed_close_retries_the_existing_queue
test_partial_close_retries_only_the_missing_contribution
test_queued_contributions_are_deduplicated_separately
test_standalone_and_task_identities_do_not_collide
test_close_reports_completed_capture_outcomes
test_refiling_retries_publication_without_a_watcher
test_lesson_copies_remain_owner_only_under_a_permissive_umask
test_git_calls_are_bounded_without_timeout_or_perl
test_watcher_tick_paces_itself_by_its_stamp
test_a_completed_task_stamps_its_final_status_not_none
test_drain_refreshes_a_read_only_mirror_after_publish() {
  local home bare out hit
  home=$(wiki_home mirror)
  bare=$(wiki_bare mirror)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_task "$home" task-m1
  printf '## retry flag\nscope: tool:no-mistakes\nclaim: pass -timeout 20m to the race step\nevidence: saw CI kill at 10m00s\n' > "$home/data/task-m1/lessons.md"
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-m1 >/dev/null || fail "close failed"
  out=$(run_wiki "$home" drain) || fail "drain must exit 0"
  assert_contains "$out" 'mirror refreshed' "the drain line reports the mirror refresh"
  hit=$(grep -rl 'wiki-task: task-m1' "$home/state/wiki/mirror" 2>/dev/null | head -n 1)
  [ -n "$hit" ] || fail "a lesson published in one task is greppable from the mirror"
  assert_contains "$hit" 'raw/' "the mirror carries the lesson under raw/"
  grep -q 'pass -timeout 20m' "$hit" || fail "the mirror carries the lesson bytes"
  assert_absent "$home/state/wiki/mirror/.git" "the mirror is a plain tree, never a second clone to write into"
  pass "drain refreshes a read-only mirror after publish"
}

test_empty_drain_still_refreshes_the_mirror() {
  local home bare out hit
  home=$(wiki_home mirrorempty)
  bare=$(wiki_bare mirrorempty)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_task "$home" task-m2
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-m2 >/dev/null || fail "close failed"
  run_wiki "$home" drain >/dev/null || fail "first drain failed"
  out=$(run_wiki "$home" drain) || fail "an empty drain must exit 0"
  assert_contains "$out" 'nothing to publish' "the empty drain still names its publish outcome"
  assert_contains "$out" 'mirror refreshed' "the empty drain still refreshes the mirror"
  hit=$(grep -rl 'wiki-task: task-m2' "$home/state/wiki/mirror" 2>/dev/null | head -n 1)
  [ -n "$hit" ] || fail "the mirror still serves the lesson after an empty drain"
  pass "an empty drain still refreshes the mirror"
}

test_offline_drain_keeps_the_last_good_mirror() {
  local home bare out before after
  home=$(wiki_home mirroroff)
  bare=$(wiki_bare mirroroff)
  wiki_cfg "$home" contributor "file://$bare"
  wiki_task "$home" task-m3
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$home" close task-m3 >/dev/null || fail "close failed"
  run_wiki "$home" drain >/dev/null || fail "first drain failed"
  before=$(wiki_mirror_fingerprint "$home/state/wiki/mirror") || fail "cannot fingerprint the mirror"
  [ "$before" != '[]' ] || fail "the first drain populated the mirror"
  mv "$bare" "$bare.away"
  out=$(run_wiki "$home" drain 2>&1) || fail "an offline drain must exit 0"
  assert_contains "$out" 'keeping the last good mirror' "the offline drain names the kept mirror"
  after=$(wiki_mirror_fingerprint "$home/state/wiki/mirror") || fail "cannot fingerprint the mirror"
  assert_equals "$before" "$after" "an offline refresh never leaves a half-updated mirror"
  grep -rl 'wiki-task: task-m3' "$home/state/wiki/mirror" 2>/dev/null | grep -q . \
    || fail "the last good mirror still serves the lesson while offline"
  mv "$bare.away" "$bare"
  out=$(run_wiki "$home" drain) || fail "the recovery drain must exit 0"
  assert_contains "$out" 'mirror refreshed' "the mirror refreshes again once the remote is back"
  pass "an offline drain keeps the last good mirror"
}

test_reader_home_drain_refreshes_mirror_without_publishing() {
  local home seed bare out hit
  bare=$(wiki_bare mirrorreader)
  seed=$(wiki_home mirrorseed)
  wiki_cfg "$seed" contributor "file://$bare"
  wiki_task "$seed" task-seed
  FM_WIKI_CLOSE_DRAIN=0 run_wiki "$seed" close task-seed >/dev/null || fail "seed close failed"
  run_wiki "$seed" drain >/dev/null || fail "seed drain failed"
  home=$(wiki_home mirrorreader)
  wiki_cfg "$home" reader "file://$bare"
  out=$(run_wiki "$home" drain) || fail "a reader drain must exit 0"
  assert_contains "$out" 'mirror refreshed' "a reader drain refreshes the mirror"
  hit=$(grep -rl 'wiki-task: task-seed' "$home/state/wiki/mirror" 2>/dev/null | head -n 1)
  [ -n "$hit" ] || fail "a reader home consults the lesson from its own mirror"
  assert_equals '1' "$(git -C "$bare" rev-list --count main)" \
    "a reader drain publishes nothing"
  pass "a reader drain refreshes the mirror without publishing"
}

test_absent_config_creates_no_mirror() {
  local home out
  home=$(wiki_home nomirror)
  out=$(run_wiki "$home" drain 2>&1) || fail "drain must exit 0 with no config"
  assert_equals '' "$out" "drain without config prints nothing"
  assert_absent "$home/state/wiki" "drain without config creates no wiki state at all"
  out=$(run_wiki "$home" brief-snippet --role reader 2>&1) || fail "reader snippet must exit 0 with no config"
  assert_equals '' "$out" "a reader snippet without config prints nothing"
  out=$(run_wiki "$home" consult printf 'must not run') || fail "missing mirror consultation must exit 0"
  assert_equals '' "$out" "a missing mirror skips the read command"
  pass "an absent config leaves every verb a silent no-op with no mirror"
}

test_consult_commands_resolve_relative_state_and_quoted_paths() {
  local home mirror out mode id
  home=$(wiki_home "consult ' \$ home")
  mirror="$home/state/wiki/mirror"
  wiki_cfg "$home" gardener "file://$TMP_ROOT/consult.git"
  mkdir -p "$mirror/pages/tools"
  : > "$home/state/wiki/.drain.lock"
  printf '# Retry flags\n> summary: retry settings\nneedle --help -timeout\n' > "$mirror/pages/tools/retry.md"
  run_wiki "$home" index --repo "$mirror" >/dev/null || fail "index generation failed"
  out=$(cd "$home" && FM_HOME="$home" FM_STATE_OVERRIDE=state "$WIKI" brief-snippet --role reader) \
    || fail "standalone consult snippet failed"
  printf '%s\n' "$out" > "$home/snippet.md"
  for mode in ship scout; do
    id="consult-$mode"
    if [ "$mode" = ship ]; then
      (cd "$home" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE=state \
        HOME="$home/home" "$BRIEF" "$id" some-proj --mode no-mistakes >/dev/null 2>&1) \
        || fail "ship consult brief failed"
    else
      (cd "$home" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE=state \
        HOME="$home/home" "$BRIEF" "$id" some-proj --scout >/dev/null 2>&1) \
        || fail "scout consult brief failed"
    fi
  done
  python3 - "$home" "$TMP_ROOT" <<'PY' || fail "emitted consult commands failed"
from pathlib import Path
import re
import subprocess
import sys

home, cwd = map(Path, sys.argv[1:])
page = 'pages/tools/retry.md'
for output in [home / 'snippet.md', *(home / f'data/consult-{kind}/brief.md' for kind in ('ship', 'scout'))]:
    text = output.read_text()
    commands = re.findall(r'`(env [^`]+ consult grep [^`]+)`', text)
    assert len(commands) == 2, (output, commands)
    for term in ('needle', '--help', '-timeout'):
        pages = subprocess.check_output(['bash', '-o', 'pipefail', '-c', commands[0].replace('<term>', term)], cwd=cwd, text=True)
        assert pages.splitlines() == [page], (output, term, pages)
    section = subprocess.check_output(['bash', '-o', 'pipefail', '-c', commands[1]], cwd=cwd, text=True)
    assert '[Retry flags](pages/tools/retry.md)' in section, (output, section)
    command, = re.findall(r'`(env [^`]+ consult cat [^`]+)`', text)
    content = subprocess.check_output(['bash', '-c', command.replace('pages/<page>.md', page)], cwd=cwd, text=True)
    assert 'needle' in content, (output, content)
PY
  pass "standalone, ship, and scout consult commands work across directories with quoted paths"
}

test_checkout_failure_never_publishes_an_incomplete_mirror() {
  local home bare seed fakebin real_git out before operation
  home=$(wiki_home checkout-failure)
  bare=$(wiki_bare checkout-failure)
  git -C "$bare" symbolic-ref HEAD refs/heads/unborn
  wiki_cfg "$home" reader "file://$bare"
  out=$(run_wiki "$home" drain) || fail "empty remote drain failed"
  assert_contains "$out" 'mirror refreshed' "a genuinely empty repository has a complete empty snapshot"
  assert_absent "$home/state/wiki/mirror/.git" "empty snapshots contain no clone metadata"
  seed="$TMP_ROOT/checkout-seed"
  git init -q "$seed"
  printf 'complete old tree\n' > "$seed/page.md"
  git -C "$seed" add page.md
  git -C "$seed" -c user.name='Wiki fixture' -c user.email=wiki@example.test commit -qm seed || fail "remote seed commit failed"
  git -C "$seed" push -q "$bare" HEAD:main || fail "remote seed failed"
  run_wiki "$home" drain >/dev/null || fail "dangling HEAD checkout failed"
  assert_equals 'complete old tree' "$(cat "$home/state/wiki/mirror/page.md")" "main is checked out when remote HEAD dangles"
  before=$(wiki_mirror_fingerprint "$home/state/wiki/mirror")
  fakebin="$TMP_ROOT/checkout-bin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_WIKI_FAIL_OPERATION" ]; then exit 124; fi
done
exec "$FM_WIKI_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  for operation in checkout for-each-ref; do
    out=$(PATH="$fakebin:$PATH" FM_WIKI_REAL_GIT="$real_git" FM_WIKI_FAIL_OPERATION="$operation" \
      run_wiki "$home" drain) || fail "failed checkout drain must stay best-effort"
    assert_contains "$out" 'checkout failed' "a failed or timed-out checkout cannot report success"
    assert_equals "$before" "$(wiki_mirror_fingerprint "$home/state/wiki/mirror")" "failed checkout preserves the old complete tree"
  done
  home=$(wiki_home checkout-first)
  wiki_cfg "$home" reader "file://$bare"
  out=$(PATH="$fakebin:$PATH" FM_WIKI_REAL_GIT="$real_git" FM_WIKI_FAIL_OPERATION=checkout \
    run_wiki "$home" drain) || fail "first checkout failure must stay best-effort"
  assert_absent "$home/state/wiki/mirror" "a first failed checkout publishes no snapshot"
  git -C "$seed" checkout -qb trunk
  printf 'remote default tree\n' > "$seed/page.md"
  git -C "$seed" -c user.name='Wiki fixture' -c user.email=wiki@example.test commit -qam default || fail "default branch commit failed"
  git -C "$seed" push -q "$bare" HEAD:trunk || fail "default branch seed failed"
  git -C "$bare" symbolic-ref HEAD refs/heads/trunk
  run_wiki "$home" drain >/dev/null || fail "default branch refresh failed"
  assert_equals 'remote default tree' "$(cat "$home/state/wiki/mirror/page.md")" "a valid remote HEAD selects the default branch"
  pass "empty remotes, dangling HEAD, and checkout failures preserve complete snapshots"
}

test_mirror_swap_keeps_the_published_tree_until_atomic_replacement() {
  local home bare seed hooks out
  home=$(wiki_home atomic-mirror)
  bare=$(wiki_bare atomic-mirror)
  seed="$TMP_ROOT/atomic-seed"
  git init -q "$seed"
  printf 'old\n' > "$seed/page.md"
  git -C "$seed" add page.md
  git -C "$seed" -c user.name='Wiki fixture' -c user.email=wiki@example.test commit -qm seed || fail "remote seed commit failed"
  git -C "$seed" push -q "$bare" HEAD:main || fail "remote seed failed"
  wiki_cfg "$home" reader "file://$bare"
  run_wiki "$home" drain >/dev/null || fail "first mirror refresh failed"
  printf 'new\n' > "$seed/page.md"
  git -C "$seed" -c user.name='Wiki fixture' -c user.email=wiki@example.test commit -qam update || fail "remote update commit failed"
  git -C "$seed" push -q "$bare" HEAD:main || fail "remote update failed"
  hooks="$TMP_ROOT/atomic-hooks"
  mkdir -p "$hooks"
  cat > "$hooks/sitecustomize.py" <<'PY'
import os
from pathlib import Path

replace = os.replace
def observe_replace(src, dst, *args, **kwargs):
    if Path(dst) != Path(os.environ['FM_WIKI_OBSERVE_MIRROR']):
        return replace(src, dst, *args, **kwargs)
    mirror = Path(dst)
    assert (mirror / 'page.md').read_text() == 'old\n'
    mirror.with_name('observed').write_text('old tree reachable at replacement')
    if os.environ.get('FM_WIKI_REJECT_SWAP') == '1':
        raise OSError('injected publication failure')
    result = replace(src, dst, *args, **kwargs)
    assert (mirror / 'page.md').read_text() == 'new\n'
    return result
os.replace = observe_replace
PY
  out=$(PYTHONPATH="$hooks" FM_WIKI_OBSERVE_MIRROR="$home/state/wiki/mirror" FM_WIKI_REJECT_SWAP=1 \
    run_wiki "$home" drain) || fail "failed swap must stay best-effort"
  assert_present "$home/state/wiki/observed" "the old tree remains reachable at the publication boundary"
  assert_contains "$out" 'swap failed' "publication failure retains the mirror"
  assert_equals 'old' "$(cat "$home/state/wiki/mirror/page.md")" "failed publication preserves old content"
  out=$(PYTHONPATH="$hooks" FM_WIKI_OBSERVE_MIRROR="$home/state/wiki/mirror" run_wiki "$home" drain) \
    || fail "atomic refresh failed"
  assert_contains "$out" 'mirror refreshed' "replacement succeeds after a failed swap"
  assert_equals 'new' "$(cat "$home/state/wiki/mirror/page.md")" "successful publication serves the new complete tree"
  assert_absent "$home/state/wiki/mirror/.git" "the refreshed tree has no clone metadata"
  assert_equals '1' "$(find "$home/state/wiki" -maxdepth 1 -type d -name '.mirror.*' | wc -l | tr -d ' ')" \
    "superseded snapshots and failed refresh scratch are removed"
  pass "mirror replacement is atomic and failed publication preserves the old tree"
}

test_active_consultations_keep_their_snapshot_until_all_readers_finish() {
  local home bare seed file
  home=$(wiki_home shared-readers)
  bare=$(wiki_bare shared-readers)
  seed="$home/seed"
  git init -q "$seed"
  mkdir -p "$seed/pages/tools" "$seed/raw"
  for file in pages/tools/retry.md index.md raw/lesson.md; do
    printf 'old needle\n' > "$seed/$file"
  done
  git -C "$seed" add .
  git -C "$seed" -c user.name='Wiki fixture' -c user.email=wiki@example.test commit -qm seed || fail "reader fixture commit failed"
  git -C "$seed" push -q "$bare" HEAD:main || fail "reader fixture push failed"
  wiki_cfg "$home" reader "file://$bare"
  run_wiki "$home" drain >/dev/null || fail "reader fixture refresh failed"
  for file in pages/tools/retry.md index.md raw/lesson.md; do
    printf 'new needle\n' > "$seed/$file"
  done
  git -C "$seed" -c user.name='Wiki fixture' -c user.email=wiki@example.test commit -qam update || fail "reader fixture update failed"
  git -C "$seed" push -q "$bare" HEAD:main || fail "reader fixture update push failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" HOME="$home/home" python3 - "$WIKI" "$home" <<'PY' \
    || fail "concurrent consultation invalidated a snapshot"
import fcntl
from pathlib import Path
import subprocess
import sys
import time

wiki, home = sys.argv[1], Path(sys.argv[2])
reader_code = '''
import os
from pathlib import Path
import subprocess
import sys
import time
with os.scandir('pages/tools') as entries:
    assert [entry.name for entry in entries] == ['retry.md']
    Path(sys.argv[1]).touch()
    deadline = time.monotonic() + 15
    while not Path(sys.argv[2]).exists():
        assert time.monotonic() < deadline, 'reader release timed out'
        time.sleep(0.01)
    matches = subprocess.check_output(['grep', '-ril', 'old needle', 'pages'], text=True)
    assert matches.splitlines() == ['pages/tools/retry.md'], matches
    for name in ('pages/tools/retry.md', 'index.md', 'raw/lesson.md'):
        assert Path(name).read_text() == 'old needle\\n', name
'''
readers = []
try:
    for number in range(2):
        ready, release = home / f'ready-{number}', home / f'release-{number}'
        process = subprocess.Popen([wiki, 'consult', sys.executable, '-c', reader_code, str(ready), str(release)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        readers.append((process, ready, release))
    deadline = time.monotonic() + 10
    while not all(ready.exists() for _, ready, _ in readers):
        assert all(process.poll() is None for process, _, _ in readers), 'a concurrent reader was skipped'
        assert time.monotonic() < deadline, 'readers never reached the directory boundary'
        time.sleep(0.01)
    mirror = home / 'state/wiki/mirror'
    snapshot = mirror.resolve()
    for process, _, release in readers:
        result = subprocess.run([wiki, 'drain'], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0 and 'already running' in result.stdout, result
        assert mirror.resolve() == snapshot and (snapshot / 'pages/tools/retry.md').exists()
        release.touch()
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, (stdout, stderr)
    result = subprocess.run([wiki, 'drain'], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and 'mirror refreshed' in result.stdout, result
    assert not snapshot.exists(), 'the retired snapshot was not reclaimed after readers finished'
    for name in ('pages/tools/retry.md', 'index.md', 'raw/lesson.md'):
        result = subprocess.run([wiki, 'consult', 'cat', name], capture_output=True, text=True, timeout=5)
        assert result.returncode == 0 and result.stdout == 'new needle\n', (name, result)
    with (home / 'state/wiki/.drain.lock').open() as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run([wiki, 'consult', 'printf', 'must not run'], capture_output=True, text=True, timeout=5)
        assert result.returncode == 0 and result.stdout == '', result
    result = subprocess.run([wiki, 'consult', 'bash', '-c', 'exit 7'], timeout=5)
    assert result.returncode == 7, result
finally:
    for process, _, release in readers:
        release.touch()
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)
PY
  pass "shared consultations retain pages, index, and raw lessons until every reader exits"
}

test_close_stays_idempotent_across_repeated_calls
test_dod_insertion_follows_the_opt_in
test_drain_refreshes_a_read_only_mirror_after_publish
test_empty_drain_still_refreshes_the_mirror
test_offline_drain_keeps_the_last_good_mirror
test_reader_home_drain_refreshes_mirror_without_publishing
test_absent_config_creates_no_mirror
test_consult_commands_resolve_relative_state_and_quoted_paths
test_checkout_failure_never_publishes_an_incomplete_mirror
test_mirror_swap_keeps_the_published_tree_until_atomic_replacement
test_active_consultations_keep_their_snapshot_until_all_readers_finish
