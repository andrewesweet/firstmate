#!/usr/bin/env bash
# tests/fm-trace-span-lib.test.sh - unit regressions for the OTLP/HTTP span
# emitter (bin/fm-trace-span-lib.sh): gate and carrier omission, wire shape
# validated as real JSON, root versus child span ids, status and link
# mapping, endpoint precedence, silent failure on a failing or slow curl,
# and the resource block rendered identical to fm_trace_attrs_render.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-span-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-trace-span-lib)

CARRIER='00-11111111111111111111111111111112-3333333333333334-01'
LINK_CARRIER='00-22222222222222222222222222222223-4444444444444445-01'

# Fake curl: appends one "ARGS: ..." line plus the raw stdin body fenced by
# --BODY-END-- markers to FM_FAKE_CURL_LOG, then optionally sleeps and exits
# with FM_FAKE_CURL_EXIT. Assertions read the OTLP JSON that would be sent.
make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' <%s>' "$@"; printf '\n'; cat; printf '\n--BODY-END--\n'; } \
  >> "${FM_FAKE_CURL_LOG:?FM_FAKE_CURL_LOG required}"
if [ -n "${FM_FAKE_CURL_SLEEP:-}" ]; then sleep "$FM_FAKE_CURL_SLEEP"; fi
exit "${FM_FAKE_CURL_EXIT:-0}"
SH
  chmod +x "$fakebin/curl"
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
  if [ -f "$1" ]; then
    grep -c '^ARGS:' "$1" || true
  else
    printf '0\n'
  fi
}

curl_body() {  # <log> <1-based request number>: the recorded stdin body
  awk -v n="$2" '
    /^ARGS:/ { c++; next }
    /^--BODY-END--$/ { if (c == n) exit; next }
    c == n { buf = buf $0 }
    END { printf "%s", buf }
  ' "$1"
}

curl_endpoint() {  # <log> <1-based request number>: the final URL argument
  awk -v n="$2" '/^ARGS:/ { c++; if (c == n) { v=$NF; gsub(/^</, "", v); gsub(/>$/, "", v); print v; exit } }' "$1"
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

test_curl_failure_and_slow_curl_stay_silent() {
  local home rc start elapsed
  home=$(make_home curl-fails)
  write_span_meta "$home/state/x1.meta"
  FM_FAKE_CURL_EXIT=7 emit "$home" firstmate.spawn - -
  rc=$?
  [ "$rc" = 0 ] || fail "a failing curl must still return 0 (got $rc)"
  FM_FAKE_CURL_SLEEP=2 emit "$home" firstmate.spawn - -
  rc=$?
  [ "$rc" = 0 ] || fail "a slow curl must still return 0 (got $rc)"
  [ "$(request_count "$home/curl.log")" = 2 ] || fail "both attempts must be recorded"
  pass "curl exit 7 and a slow curl both return 0 silently"
}

test_resource_identical_to_attrs_render() {
  local home body rendered from_body
  home=$(make_home resource-render)
  write_span_meta "$home/state/x1.meta"
  emit "$home" firstmate.spawn - -
  body=$(curl_body "$home/curl.log" 1)
  rendered=$(fm_trace_attrs_render "$home/state/x1.meta")
  from_body=$(jq -r '.resourceSpans[0].resource.attributes[1:] | map(.key + "=" + .value.stringValue) | join(",")' <<< "$body")
  [ "$from_body" = "$rendered" ] \
    || fail "resource attributes must equal fm_trace_attrs_render (body='$from_body' render='$rendered')"
  pass "resource block after service.name is exactly fm_trace_attrs_render"
}

test_link_from_meta_and_explicit_flag() {
  local home body
  home=$(make_home links)
  fm_write_meta "$home/state/x1.meta" \
    "endpoint_task_id=x1" \
    "traceparent=$CARRIER" \
    "trace_link=$LINK_CARRIER"
  emit "$home" firstmate.task - - --root
  body=$(curl_body "$home/curl.log" 1)
  span0 '.links[0].traceId == "22222222222222222222222222222223" and .links[0].spanId == "4444444444444445"' "$body" \
    || fail "a recorded trace_link= must become one span link"
  emit "$home" firstmate.task - - --root --link '00-33333333333333333333333333333334-5555555555555556-01'
  body=$(curl_body "$home/curl.log" 2)
  span0 '.links[0].spanId == "5555555555555556"' "$body" \
    || fail "an explicit --link must override the meta link"
  fm_write_meta "$home/state/x1.meta" \
    "endpoint_task_id=x1" \
    "traceparent=$CARRIER" \
    "trace_link=not-a-carrier"
  emit "$home" firstmate.task - - --root
  body=$(curl_body "$home/curl.log" 3)
  span0 '(.links? == null)' "$body" \
    || fail "an invalid link value must be silently dropped"
  pass "links: meta trace_link, explicit --link override, invalid dropped"
}

test_attrs_encode_and_render_keys() {
  local out meta
  out=$(fm_trace_attrs_encode 'my path/x, y')
  [ "$out" = 'my%20path/x%2C%20y' ] || fail "encode got '$out'"
  out=$(fm_trace_attrs_encode 'safe._-~/plain')
  [ "$out" = 'safe._-~/plain' ] || fail "the allowed charset must pass through (got '$out')"
  mkdir -p "$TMP_ROOT/state"
  meta="$TMP_ROOT/state/render-ship.meta"
  fm_write_meta "$meta" \
    "endpoint_task_id=x1" \
    "project=/tmp/spans/my proj" \
    "kind=ship" \
    "harness=claude" \
    "spawn_gen=s9.8.7"
  out=$(fm_trace_attrs_render "$meta")
  [ "$out" = 'firstmate.task.id=x1,firstmate.project=my%20proj,firstmate.home='"$(fm_trace_attrs_encode "$TMP_ROOT")"',firstmate.task.kind=ship,firstmate.harness=claude,firstmate.spawn_gen=s9.8.7' ] \
    || fail "render keys/order got '$out'"
  case $out in
    *firstmate.secondmate.id*) fail "a ship render must not carry secondmate.id" ;;
  esac
  meta="$TMP_ROOT/state/render-sm.meta"
  fm_write_meta "$meta" \
    "endpoint_task_id=sm-1" \
    "kind=secondmate" \
    "model=default"
  out=$(fm_trace_attrs_render "$meta")
  case $out in
    *firstmate.secondmate.id=sm-1*) : ;;
    *) fail "a secondmate render must carry firstmate.secondmate.id=<task id> (got '$out')" ;;
  esac
  case $out in
    *firstmate.harness*) fail "an absent key must be omitted (got '$out')" ;;
  esac
  out=$(fm_trace_attrs_render "$TMP_ROOT/state/render-absent.meta")
  [ -z "$out" ] || fail "an absent meta must render nothing (got '$out')"
  pass "render: key list, encoding, secondmate id only for kind=secondmate"
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
test_curl_failure_and_slow_curl_stay_silent
test_resource_identical_to_attrs_render
test_link_from_meta_and_explicit_flag
test_attrs_encode_and_render_keys
test_absent_meta_is_silent_no_op

echo "# all fm-trace-span-lib tests passed"
