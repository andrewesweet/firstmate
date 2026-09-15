#!/usr/bin/env bash
# tests/fm-precompact-skills.test.sh - behavior tests for
# bin/fm-precompact-skills.sh, the Claude PreCompact hook that records which
# skills a session had loaded before compaction voids their bodies.
#
# Coverage:
#   - a synthetic transcript with two distinct Skill calls, one duplicated:
#     the record holds the de-duplicated names in first-load order, and the
#     hook exits 0
#   - non-Skill tool_use, text mentions, and nested keys never reach the record
#   - an empty transcript file, a missing transcript_path, an unreadable
#     transcript path, and an empty payload each still write an EMPTY record
#     and exit 0
#   - the hook is silent on stdout and stderr: PreCompact exit 0 stdout would
#     be appended to the compaction's own instructions, and this hook must
#     never speak into it
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-precompact-skills.sh"
TMP_ROOT=$(fm_test_tmproot fm-precompact-skills-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/state"
  printf '%s\n' "$w"
}

# run_hook <world> <payload> [transcript-content-file]
# Feeds the payload on stdin and echoes the hook's combined output; the
# caller checks $hook_rc for the exit status.
run_hook() {
  local world=$1 payload=$2
  printf '%s' "$payload" | FM_STATE_OVERRIDE="$world/state" "$HOOK" 2>&1
}

test_two_skill_calls_with_duplicate_record_in_first_load_order() {
  local world out rc
  world=$(new_world dedup)
  cat > "$world/transcript.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Loading the skill named harness-adapters now, this text is not a tool call."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"harness-adapters"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Skill","input":{"skill":"ask-user-authority","args":"since main"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"echo skill: bash-skill-lookalike","description":"lookalike"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Skill","input":{"skill":"harness-adapters"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t5","name":"Skill","input":{"skill":"captain-hold-lifecycle"}}]}}
EOF
  out=$(run_hook "$world" '{"session_id":"s1","transcript_path":"'"$world"'/transcript.jsonl","hook_event_name":"PreCompact","trigger":"manual"}')
  rc=$?
  expect_code 0 "$rc" "hook exited nonzero on a readable transcript"
  [ -z "$out" ] || fail "the hook printed to stdout or stderr: $out"
  [ "$(cat "$world/state/.compact-skills")" = "harness-adapters
ask-user-authority
captain-hold-lifecycle" ] \
    || fail "record is not the de-duplicated first-load-ordered skill list: $(cat "$world/state/.compact-skills")"
  pass "two Skill calls with one duplicate record de-duplicated in first-load order and exit 0"
}

test_empty_transcript_writes_empty_record() {
  local world out rc
  world=$(new_world empty)
  : > "$world/transcript.jsonl"
  out=$(run_hook "$world" '{"transcript_path":"'"$world"'/transcript.jsonl"}')
  rc=$?
  expect_code 0 "$rc" "hook exited nonzero on an empty transcript"
  [ -z "$out" ] || fail "the hook printed on an empty transcript: $out"
  assert_present "$world/state/.compact-skills" "an empty transcript did not write the record"
  [ ! -s "$world/state/.compact-skills" ] || fail "an empty transcript produced a non-empty record"
  pass "an empty transcript writes an empty record and exits 0"
}

test_missing_and_unreadable_transcript_write_empty_records() {
  local world out rc
  world=$(new_world unreadable)
  out=$(run_hook "$world" '{"transcript_path":"'"$world"'/never-written.jsonl"}')
  rc=$?
  expect_code 0 "$rc" "hook exited nonzero on an unreadable transcript path"
  [ -z "$out" ] || fail "the hook printed on an unreadable transcript: $out"
  [ ! -s "$world/state/.compact-skills" ] || fail "an unreadable transcript produced a non-empty record"

  out=$(run_hook "$world" '{"session_id":"s2"}')
  rc=$?
  expect_code 0 "$rc" "hook exited nonzero on a payload without transcript_path"
  [ ! -s "$world/state/.compact-skills" ] || fail "a missing transcript_path produced a non-empty record"

  out=$(printf '' | FM_STATE_OVERRIDE="$world/state" "$HOOK" 2>&1)
  rc=$?
  expect_code 0 "$rc" "hook exited nonzero on an empty payload"
  [ ! -s "$world/state/.compact-skills" ] || fail "an empty payload produced a non-empty record"
  pass "missing and unreadable transcripts write empty records and exit 0"
}

test_terminal_stdin_does_not_block() {
  local world
  world=$(new_world terminal)
  # A manual invocation without piped stdin: run_hook always pipes, so drive
  # the terminal-stdin branch directly under </dev/null, which [ -t 0 ] treats
  # the same way for this contract: no hang, empty record, exit 0.
  timeout 10 env FM_STATE_OVERRIDE="$world/state" "$HOOK" </dev/null >/dev/null 2>&1
  local rc=$?
  expect_code 0 "$rc" "hook did not exit 0 without piped stdin"
  [ ! -s "$world/state/.compact-skills" ] || fail "a stdin-less invocation produced a non-empty record"
  pass "an invocation without piped stdin exits 0 without hanging"
}

test_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$HOOK" 2>&1) \
    || fail "bin/fm-precompact-skills.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-precompact-skills.sh is clean under bin/fm-lint.sh"
}

test_two_skill_calls_with_duplicate_record_in_first_load_order
test_empty_transcript_writes_empty_record
test_missing_and_unreadable_transcript_write_empty_records
test_terminal_stdin_does_not_block
test_shellcheck_clean
