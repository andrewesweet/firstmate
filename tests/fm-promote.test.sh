#!/usr/bin/env bash
# tests/fm-promote.test.sh - fm-promote.sh's published-promotion trace span.
#
# Promotion is the scout-to-ship contract flip: fm-promote.sh publishes the
# rewritten task record, and the firstmate.promote span marks that event on
# the task's own trace (bin/fm-trace-span-lib.sh's header owns the
# catalogue). These tests drive the real fm-promote executable against an
# isolated home with a fake curl that records the OTLP request, pinning:
#   1. An enabled home posts exactly one firstmate.promote span parenting on
#      the task's carrier, carrying firstmate.task.kind.prior=scout,
#      firstmate.task.mode, and firstmate.task.yolo, with the published
#      record's kind=ship in the resource.
#   2. A disabled home posts nothing and still promotes.
#   3. A failing emitter cannot fail the promotion.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

CARRIER='00-11111111111111111111111111111113-4444444444444445-01'

setup_case() {  # <name> [on|off] -> echoes case dir
  local name=$1 effective=${2:-on} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data/sc1"
  fm_test_otlp_capture_install "$(fm_fakebin "$dir")"
  fm_write_meta "$dir/home/state/sc1.meta" \
    "window=fmses:fm-sc1" \
    "endpoint_task_id=sc1" \
    "project=$dir/proj" \
    "worktree=$dir/wt" \
    "harness=claude" \
    "kind=scout" \
    "model=default" \
    "effort=default"
  {
    echo "# Task"
    echo "## Captain's intent"
    echo "Promote this scout and ship the fix it found."
    echo
    echo "## Firstmate spec"
    echo "Carry the reproduced bug in as a regression test."
  } > "$dir/home/data/sc1/brief.md"
  fm_test_otlp_trace_enable "$dir/home" sc1 "$CARRIER" "$effective"
  printf '%s\n' "$dir"
}

run_promote() {  # <case-dir> [extra env...] -- <args...>
  local dir=$1
  shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_FAKE_CURL_LOG="$dir/curl.log" ${envs[@]+"${envs[@]}"} \
    "$PROMOTE" "$@" 2>"$dir/promote.err"
}

test_promotion_emits_span_with_contract_attributes() {
  local dir body rc
  dir=$(setup_case promote-span)
  run_promote "$dir" -- sc1 --mode no-mistakes --yolo off; rc=$?
  expect_code 0 "$rc" "promotion should succeed"$'\n'"$(cat "$dir/promote.err")"
  grep -q '^kind=ship$' "$dir/home/state/sc1.meta" \
    || fail "promotion did not publish kind=ship"
  [ "$(fm_test_otlp_request_count "$dir/curl.log")" = 1 ] \
    || fail "exactly one span request expected, got $(fm_test_otlp_request_count "$dir/curl.log")"
  body=$(fm_test_otlp_request_body "$dir/curl.log" 1)
  fm_test_otlp_span_matches '.name == "firstmate.promote" and .kind == 1' "$body" \
    || fail "the span must be firstmate.promote with INTERNAL kind"
  fm_test_otlp_span_matches ".traceId == \"${CARRIER:3:32}\"" "$body" \
    || fail "the span must ride the task's trace"
  fm_test_otlp_span_matches ".parentSpanId == \"${CARRIER:36:16}\"" "$body" \
    || fail "the span must parent on the task's carrier span id"
  [ "$(fm_test_otlp_span_attr firstmate.task.kind.prior "$body")" = scout ] \
    || fail "the span must record the prior kind"
  [ "$(fm_test_otlp_span_attr firstmate.task.mode "$body")" = no-mistakes ] \
    || fail "the span must record the promoted mode"
  [ "$(fm_test_otlp_span_attr firstmate.task.yolo "$body")" = off ] \
    || fail "the span must record the promoted yolo posture"
  jq -e '[.resourceSpans[0].resource.attributes[] | select(.key == "firstmate.task.kind")][0].value.stringValue == "ship"' \
    >/dev/null <<< "$body" \
    || fail "the resource must read the published record's kind=ship"
  pass "fm-promote: the published promotion posts one span with the contract flip on the task's trace"
}

test_disabled_home_promotes_without_span() {
  local dir rc
  dir=$(setup_case promote-off off)
  run_promote "$dir" -- sc1 --mode direct-PR --yolo on; rc=$?
  expect_code 0 "$rc" "promotion should succeed while tracing is disabled"$'\n'"$(cat "$dir/promote.err")"
  grep -q '^kind=ship$' "$dir/home/state/sc1.meta" \
    || fail "a disabled home must still promote"
  [ "$(fm_test_otlp_request_count "$dir/curl.log")" = 0 ] \
    || fail "a disabled home must post no span"
  pass "fm-promote: a disabled home promotes identically and posts nothing"
}

test_failing_emitter_cannot_fail_promotion() {
  local dir rc
  dir=$(setup_case promote-curl-fail)
  run_promote "$dir" FM_FAKE_CURL_EXIT=7 -- sc1 --mode local-only --yolo off; rc=$?
  expect_code 0 "$rc" "a refused collector must not fail the promotion"$'\n'"$(cat "$dir/promote.err")"
  grep -q '^kind=ship$' "$dir/home/state/sc1.meta" \
    || fail "the promotion must still publish through an emitter failure"
  pass "fm-promote: an emitter failure cannot alter the promotion outcome"
}

test_promotion_emits_span_with_contract_attributes
test_disabled_home_promotes_without_span
test_failing_emitter_cannot_fail_promotion

echo "# all fm-promote tests passed"
