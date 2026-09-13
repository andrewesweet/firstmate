#!/usr/bin/env bash
# tests/fm-trace-span-lib.test.sh - unit regressions for the OTLP/HTTP span
# emitter (bin/fm-trace-span-lib.sh): gate and carrier omission, wire shape
# validated as real JSON, root versus child span ids, status
# mapping, endpoint precedence, silent failure on collector refusal or timeout,
# and resource values preserved in the emitted JSON.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-span-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-trace-span-lib)

CARRIER='00-11111111111111111111111111111112-3333333333333334-01'

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_test_otlp_capture_install "$fakebin"
  printf '%s\n' "$fakebin"
}

# Build one home with a locked session, an effective decision the emitter
# reads, and the fake curl first in PATH. <effective> is on or off.
make_home() {  # <name> [on|off]
  local dir="$TMP_ROOT/$1" effective=${2:-on} fakebin
  mkdir -p "$dir/state" "$dir/config"
  printf '%s\n' $$ > "$dir/state/.lock"
  printf '%s %s\n' "$$" "$effective" > "$dir/state/.trace-context-effective"
  fakebin=$(make_fakebin "$dir/fake")
  printf '%s\n' "$dir"
}

write_span_meta() {  # <meta-file>
  fm_write_meta "$1" \
    "window=firstmate:fm-x1" \
    "endpoint_task_id=x1" \
    "project=/tmp/spans/proj" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "harness=claude" \
    "model=opus" \
    "effort=low" \
    "spawn_gen=s9.8.7" \
    "traceparent=$CARRIER" \
    "trace_started=1700000000000"
}

emit() {  # <home> <emit-args...>: one emission through the fake curl
  local home=$1
  shift
  FM_FAKE_CURL_LOG="$home/curl.log" PATH="$home/fake/fakebin:$PATH" \
    fm_trace_span_emit "$home/state/x1.meta" "$@"
}

request_count() {  # <log>
  fm_test_otlp_request_count "$1"
}

curl_body() {  # <log> <1-based request number>: the recorded stdin body
  fm_test_otlp_request_body "$1" "$2"
}

curl_endpoint() {  # <log> <1-based request number>: the final URL argument
  fm_test_otlp_request_endpoint "$1" "$2"
}

span0() {  # <jq-filter> <body>: true when the filter holds on the first span
  jq -e '.resourceSpans[0].scopeSpans[0].spans[0] | '"$1" >/dev/null 2>&1 <<< "$2"
}

span_value() {  # <jq-filter> <body>: echo the filter result on the first span
  jq -r "$1" <(jq '.resourceSpans[0].scopeSpans[0].spans[0]' <<< "$2")
}

test_no_carrier_posts_nothing() {
  local home
  home=$(make_home no-carrier)
  fm_write_meta "$home/state/x1.meta" "window=firstmate:fm-x1"
  emit "$home" firstmate.spawn - - firstmate.relaunch=false
  [ "$(request_count "$home/curl.log")" = 0 ] \
    || fail "an untraced meta must produce no request"
  pass "no recorded carrier -> no request"
}

test_session_off_posts_nothing() {
  local home
  home=$(make_home session-off off)
  write_span_meta "$home/state/x1.meta"
  emit "$home" firstmate.spawn - -
  [ "$(request_count "$home/curl.log")" = 0 ] \
    || fail "a frozen off decision must produce no request"
  pass "frozen session decision off -> no request"
}

test_child_body_shape() {
  local home body
  home=$(make_home child-shape)
  write_span_meta "$home/state/x1.meta"
  emit "$home" firstmate.spawn 1700000000001 1700000001234 firstmate.relaunch=false
  [ "$(request_count "$home/curl.log")" = 1 ] || fail "exactly one request expected"
  body=$(curl_body "$home/curl.log" 1)
  span0 '.name == "firstmate.spawn" and .kind == 1' "$body" \
    || fail "span must carry the given name and INTERNAL kind"
  span0 '.traceId == "11111111111111111111111111111112"' "$body" \
    || fail "traceId must be the carrier's trace id"
  span_value '.spanId' "$body" | grep -Eq '^[0-9a-f]{16}$' \
    || fail "a child span id must be 16 lowercase hex chars"
  [ "$(span_value '.spanId' "$body")" != "${CARRIER:36:16}" ] \
    || fail "a child span must not reuse the carrier's span id"
  [ "$(span_value '.parentSpanId' "$body")" = "${CARRIER:36:16}" ] \
    || fail "the child's parent must be the carrier's span id"
  [ "$(span_value '.startTimeUnixNano' "$body")" = 1700000000001000000 ] \
    || fail "start must be the given epoch ms as nanoseconds"
  [ "$(span_value '.endTimeUnixNano' "$body")" = 1700000001234000000 ] \
    || fail "end must be the given epoch ms as nanoseconds"
  jq -e '.resourceSpans[0].scopeSpans[0].scope.name == "firstmate"' >/dev/null <<< "$body" \
    || fail "the scope name must be firstmate"
  jq -e '[.resourceSpans[0].resource.attributes[] | select(.key == "service.name")][0].value.stringValue == "firstmate"' >/dev/null <<< "$body" \
    || fail "the resource must carry service.name=firstmate"
  span0 '(.status? == null) and (.links? == null)' "$body" \
    || fail "a default child must carry no status and no links"
  pass "child body: valid OTLP/JSON shape with hex ids, parent, nanos, scope"
}

test_root_uses_carrier_span_id() {
  local home body
  home=$(make_home root-id)
  write_span_meta "$home/state/x1.meta"
  emit "$home" firstmate.task 1700000000000 1700000001000 --root --status ok firstmate.task.outcome=done
  body=$(curl_body "$home/curl.log" 1)
  span0 '.spanId == "3333333333333334"' "$body" \
    || fail "the root span id must be the carrier's span id"
  span0 '(.parentSpanId? == null)' "$body" \
    || fail "the root span must be parentless"
  span0 '.status.code == 1' "$body" \
    || fail "--status ok must map to OTLP code 1"
  pass "root: carrier span id, parentless, ok status"
}

test_status_mapping() {
  local home body
  home=$(make_home status-map)
  write_span_meta "$home/state/x1.meta"
  emit "$home" firstmate.task - - --root --status error firstmate.task.outcome=failed
  body=$(curl_body "$home/curl.log" 1)
  span0 '.status.code == 2' "$body" || fail "--status error must map to OTLP code 2"
  emit "$home" firstmate.spawn - -
  body=$(curl_body "$home/curl.log" 2)
  span0 '(.status? == null)' "$body" || fail "an omitted --status must stay UNSET"
  pass "status mapping: error -> 2, omitted -> unset field"
}

test_clamped_and_now_timestamps() {
  local home body before after
  home=$(make_home timestamps)
  write_span_meta "$home/state/x1.meta"
  before=$(fm_timing_now_ms)
  emit "$home" firstmate.spawn - -
  after=$(fm_timing_now_ms)
  body=$(curl_body "$home/curl.log" 1)
  jq -e --argjson b "$before" --argjson a "$after" \
    '(.resourceSpans[0].scopeSpans[0].spans[0].startTimeUnixNano | tonumber) >= ($b * 1000000) and (.resourceSpans[0].scopeSpans[0].spans[0].endTimeUnixNano | tonumber) <= ($a * 1000000)' >/dev/null <<< "$body" \
    || fail "dash timestamps must fall inside the test window"
  jq -e '.resourceSpans[0].scopeSpans[0].spans[0].startTimeUnixNano <= .resourceSpans[0].scopeSpans[0].spans[0].endTimeUnixNano' >/dev/null <<< "$body" \
    || fail "two dash timestamps must still order start before end"
  emit "$home" firstmate.spawn 1700000001000 1700000000000
  body=$(curl_body "$home/curl.log" 2)
  [ "$(span_value '.endTimeUnixNano' "$body")" = "$(span_value '.startTimeUnixNano' "$body")" ] \
    || fail "an end before its start must clamp to the start"
  pass "timestamps: dash means now and end-before-start clamps"
}

test_endpoint_precedence() {
  local home
  home=$(make_home endpoints)
  write_span_meta "$home/state/x1.meta"
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT='http://traces:9/v1/traces' \
    OTEL_EXPORTER_OTLP_ENDPOINT='http://base:9' \
    emit "$home" firstmate.spawn - -
  [ "$(curl_endpoint "$home/curl.log" 1)" = 'http://traces:9/v1/traces' ] \
    || fail "the traces-specific endpoint must win"
  OTEL_EXPORTER_OTLP_ENDPOINT='http://base:9/' \
    emit "$home" firstmate.spawn - -
  [ "$(curl_endpoint "$home/curl.log" 2)" = 'http://base:9/v1/traces' ] \
    || fail "the base endpoint must gain /v1/traces and lose its trailing slash"
  emit "$home" firstmate.spawn - -
  [ "$(curl_endpoint "$home/curl.log" 3)" = 'http://127.0.0.1:4318/v1/traces' ] \
    || fail "the loopback default endpoint must be last"
  pass "endpoint precedence: traces endpoint, base endpoint, loopback default"
}

test_curl_failure_stays_silent_under_errexit() {
  local home rc output exit_code
  home=$(make_home curl-fails)
  write_span_meta "$home/state/x1.meta"
  for exit_code in 7 28; do
    output=$(FM_FAKE_CURL_LOG="$home/curl.log" FM_FAKE_CURL_EXIT="$exit_code" \
      PATH="$home/fake/fakebin:$PATH" bash -e -u -o pipefail -c '
        . "$1/bin/fm-trace-span-lib.sh"
        fm_trace_span_emit "$2/state/x1.meta" firstmate.spawn - -
        printf "continued"
      ' _ "$ROOT" "$home" 2>&1)
    rc=$?
    [ "$rc" = 0 ] && [ "$output" = continued ] \
      || fail "curl exit $exit_code must preserve strict caller execution silently (rc=$rc output=$output)"
  done
  [ "$(request_count "$home/curl.log")" = 2 ] || fail "both attempts must be recorded"
  pass "curl refusal and timeout preserve caller execution under errexit and pipefail"
}

test_resource_values() {
  local home body project
  home=$(make_home resource-values)
  project=$'my proj,=50% "quoted" \\ café\tend'
  fm_write_meta "$home/state/x1.meta" \
    "endpoint_task_id=x1" \
    "project=/tmp/$project" \
    "kind=ship" \
    "harness=claude" \
    "model=opus" \
    "effort=low" \
    "spawn_gen=s9.8.7" \
    "traceparent=$CARRIER"
  emit "$home" firstmate.spawn - -
  body=$(curl_body "$home/curl.log" 1)
  jq -e --arg project "$project" --arg home "$home" '
    .resourceSpans[0].resource.attributes |
    map({key: .key, value: .value.stringValue}) | from_entries |
    . == {
      "service.name": "firstmate",
      "firstmate.task.id": "x1",
      "firstmate.project": $project,
      "firstmate.home": $home,
      "firstmate.task.kind": "ship",
      "firstmate.harness": "claude",
      "firstmate.model": "opus",
      "firstmate.effort": "low",
      "firstmate.spawn_gen": "s9.8.7"
    }' >/dev/null <<< "$body" || fail "resource JSON must preserve original metadata values"
  fm_write_meta "$home/state/x1.meta" \
    "endpoint_task_id=sm-1" "kind=secondmate" "traceparent=$CARRIER"
  emit "$home" firstmate.spawn - -
  body=$(curl_body "$home/curl.log" 2)
  jq -e --arg home "$home" '
    .resourceSpans[0].resource.attributes |
    map({key: .key, value: .value.stringValue}) | from_entries |
    . == {
      "service.name": "firstmate",
      "firstmate.task.id": "sm-1",
      "firstmate.home": $home,
      "firstmate.task.kind": "secondmate",
      "firstmate.secondmate.id": "sm-1"
    }' >/dev/null <<< "$body" || fail "secondmate identity and omitted metadata must match"
  pass "resource JSON preserves values, includes secondmate identity, omits absent keys"
}

test_absent_meta_is_silent_no_op() {
  local home
  home=$(make_home absent-meta)
  emit "$home" firstmate.spawn - -
  [ "$(request_count "$home/curl.log")" = 0 ] \
    || fail "an absent meta file must produce no request"
  pass "absent meta file -> silent no-op"
}

test_no_carrier_posts_nothing
test_session_off_posts_nothing
test_child_body_shape
test_root_uses_carrier_span_id
test_status_mapping
test_clamped_and_now_timestamps
test_endpoint_precedence
test_curl_failure_stays_silent_under_errexit
test_resource_values
test_absent_meta_is_silent_no_op

echo "# all fm-trace-span-lib tests passed"
