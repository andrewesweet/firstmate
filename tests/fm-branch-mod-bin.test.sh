#!/usr/bin/env bash
# tests/fm-branch-mod-bin.test.sh - the bin surface behind the Claude Code
# supervision-branch mod (docs/claude-supervision-branch.md): the classifier
# evidence bundle and its per-task offset, the routine-covered backstop
# extension of the main drain, and the classification-log scorer; teardown of
# the offset file is covered by tests/fm-teardown.test.sh. Every piece is inert without state/.branch-mod-mode.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
EVIDENCE="$ROOT/bin/fm-wake-evidence.sh"
OUTCOMES="$ROOT/bin/fm-branch-outcome.sh"
SCORE="$ROOT/bin/fm-branch-classifier-score.sh"
# shellcheck disable=SC2034 # make_case reads it
TMP_ROOT=$(fm_test_tmproot fm-branch-mod-bin-tests)

set_mtime() {  # <epoch> <file>
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

append_outcome() {  # <state> <task> <verdict> <summary>
  FM_STATE_OVERRIDE="$1" "$OUTCOMES" append \
    --task "$2" --verdict "$3" --summary "$4" >/dev/null
}

backstop_body() {  # <drain-output>
  awk '
    /^STATUS OUTCOME BACKSTOP \(/ { in_section=1; next }
    in_section && /^(OPEN DECISIONS|RECORD DIVERGENCE|UNREAD STATUS|WAKE_ACK_REQUIRED)/ { exit }
    in_section { print }
  ' "$1"
}

test_evidence_bundle_marks_new_lines_and_advances_the_offset() {
  local dir state out
  dir=$(make_case evidence)
  state="$dir/state"
  out="$dir/evidence.out"
  printf 'working: started\ndone: PR https://example.test/1 checks green\n' > "$state/t1.status"

  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "evidence bundle failed: $(cat "$out")"
  head -n 1 "$out" | grep -qx '## task t1 status bytes 0-62' \
    || fail "first bundle did not name the whole log as its byte range: $(head -n 1 "$out")"
  grep -q '^  done: PR https://example.test/1 checks green$' "$out" \
    || fail "the done line was not presented as NEW: $(cat "$out")"
  [ "$(cat "$state/.t1.classifier-offset")" = 62 ] \
    || fail "the offset file was not advanced to the log size: $(cat "$state/.t1.classifier-offset")"

  printf 'working: follow-up\n' >> "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "second evidence bundle failed"
  head -n 1 "$out" | grep -qx '## task t1 status bytes 62-81' \
    || fail "second bundle did not start at the previous offset: $(head -n 1 "$out")"
  grep -q '^  working: follow-up$' "$out" || fail "the appended line was not presented as NEW"
  awk '/HISTORY/ { h=1; next } h && /done: PR/ { found=1 } END { exit found ? 0 : 1 }' "$out" \
    || fail "the earlier done line was not presented as HISTORY: $(cat "$out")"

  : > "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "evidence bundle after a log reset failed"
  head -n 1 "$out" | grep -qx '## task t1 status bytes 0-0' \
    || fail "a shrunken log did not reset the offset: $(head -n 1 "$out")"

  FM_STATE_OVERRIDE="$state" "$EVIDENCE" 'bad task' > "$out" 2>&1 && fail "an invalid task id was accepted"
  pass "the evidence bundle presents NEW and HISTORY lines by byte offset and owns the per-task offset file"
}

test_routine_covered_lines_surface_only_under_the_mod() {
  local dir state out body old
  dir=$(make_case routine-covered)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: PR https://example.test/2 checks green\n' > "$state/t2.status"
  set_mtime "$old" "$state/t2.status"
  append_outcome "$state" t2 routine 'branch judged the completion routine'

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed without the mod"
  if grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null; then
    fail "a routine-covered line surfaced in a home without the mod: $(cat "$out")"
  fi
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" --routine-covered t2 > "$out" || fail "routine-covered listing failed"
  grep -q "$(printf '^45\tdone: PR https://example.test/2 checks green$')" "$out" \
    || fail "the routine-covered listing did not name the covered line and its end offset: $(cat "$out")"

  : > "$state/.branch-mod-mode"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed under the mod"
  grep -F 'STATUS OUTCOME BACKSTOP (captain-facing task event with no covering branch outcome, or covered only by a ROUTINE one):' "$out" >/dev/null \
    || fail "the routine-covered backstop did not surface under the mod: $(cat "$out")"
  body=$(backstop_body "$out")
  case "$body" in *'t2 done: PR https://example.test/2 checks green (covered by a ROUTINE branch outcome)'*) ;; *) fail "the covered line was not presented with its provenance: $body" ;; esac

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second main drain failed under the mod"
  if grep -F 'covered by a ROUTINE branch outcome' "$out" >/dev/null; then
    fail "a routine-covered line was re-presented on the next drain: $(cat "$out")"
  fi

  printf 'working: rebased\n' > "$state/t3.status"
  set_mtime "$old" "$state/t3.status"
  append_outcome "$state" t3 routine 'progress only'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed for a routine-only task"
  if grep -F 't3 ' "$out" >/dev/null; then
    fail "a routine status line covered by a routine outcome was presented: $(cat "$out")"
  fi

  printf 'done: PR https://example.test/4 checks green\n' > "$state/t4.status"
  set_mtime "$old" "$state/t4.status"
  append_outcome "$state" t4 captain 'completion reached main'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed for a captain-covered task"
  if grep -F 't4 ' "$out" >/dev/null; then
    fail "a line covered by a CAPTAIN outcome was re-presented under the mod: $(cat "$out")"
  fi
  pass "a captain-facing line covered only by a ROUTINE branch outcome surfaces once on the main drain, only under the mod"
}

test_routine_covered_lines_are_byte_exact_across_outcomes() {
  local dir state out old
  dir=$(make_case routine-covered-offsets)
  state="$dir/state"
  out="$dir/covered.out"
  old=$(( $(date +%s) - 20 ))
  : > "$state/.branch-mod-mode"

  printf 'done: first completion\n' > "$state/t5.status"
  set_mtime "$old" "$state/t5.status"
  append_outcome "$state" t5 captain 'first completion reached main'
  printf 'failed: second attempt failed\n' >> "$state/t5.status"
  append_outcome "$state" t5 routine 'branch judged the failure routine'

  FM_STATE_OVERRIDE="$state" "$EVIDENCE" --routine-covered t5 > "$out" || fail "routine-covered listing failed"
  [ "$(wc -l < "$out" | tr -d ' ')" = 1 ] || fail "expected exactly the one line the routine outcome covered, got: $(cat "$out")"
  grep -q "$(printf '\tfailed: second attempt failed$')" "$out" \
    || fail "the line under the routine outcome was not listed: $(cat "$out")"
  pass "only the lines between the previous outcome's endpoint and the routine outcome's endpoint are listed"
}

test_scorer_labels_records_from_the_status_bytes_they_judged() {
  local dir state out
  dir=$(make_case scorer)
  state="$dir/state"
  out="$dir/score.out"
  printf 'working: a\ndone: PR https://example.test/6 checks green\n' > "$state/t6.status"
  printf 'working: b\n' > "$state/t7.status"
  {
    printf '{"t":"x","verdict":"routine","model":"haiku","evidence":[{"task":"t6","from":0,"to":56}]}\n'
    printf '{"t":"x","verdict":"captain","model":"haiku","evidence":[{"task":"t6","from":0,"to":56}]}\n'
    printf '{"t":"x","verdict":"routine","model":"haiku","evidence":[{"task":"t7","from":0,"to":11}]}\n'
    printf '{"t":"x","verdict":"uncertain","model":"haiku","evidence":[{"task":"t7","from":0,"to":11}]}\n'
    printf '{"t":"x","verdict":"routine","model":"sonnet","evidence":[{"task":"gone","from":0,"to":11}]}\n'
    printf 'not json\n'
  } > "$state/branch-mod-classifications.jsonl"

  FM_STATE_OVERRIDE="$state" "$SCORE" -v > "$out" || fail "scorer failed: $(cat "$out")"
  grep -q '^| haiku | 4 | 2 / 1 / 1 | 1 | 1 | 1 | 1 | 0 |$' "$out" \
    || fail "haiku row is wrong: $(cat "$out")"
  grep -q '^| sonnet | 1 | 1 / 0 / 0 | 0 | 0 | 0 | 0 | 1 |$' "$out" \
    || fail "sonnet row did not count the torn-down task as unscorable: $(cat "$out")"
  grep -q '^- record 1 (haiku): label captain, verdict routine CAPTAIN MISS: t6,0,56$' "$out" \
    || fail "the false-routine record was not listed as a captain miss: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$SCORE" "$state/absent.jsonl" > "$out" || fail "scorer failed on an absent log"
  [ "$(wc -l < "$out" | tr -d ' ')" = 2 ] || fail "an absent log must print only the table header: $(cat "$out")"
  pass "the scorer labels each record from the status bytes it judged and reports false-routine verdicts as captain misses"
}

test_evidence_bundle_marks_new_lines_and_advances_the_offset
test_routine_covered_lines_surface_only_under_the_mod
test_routine_covered_lines_are_byte_exact_across_outcomes
test_scorer_labels_records_from_the_status_bytes_they_judged
