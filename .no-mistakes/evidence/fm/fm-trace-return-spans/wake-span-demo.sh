#!/usr/bin/env bash
# Manual end-to-end demo: queue rows for a traced task, a heartbeat, a check
# and a stale row; present; acknowledge; show the OTLP body the drain posts.
set -u
ROOT=$1
. "$ROOT/tests/wake-helpers.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"; TMP_ROOT=$(fm_test_tmproot fm-wake-demo); trap 'rm -rf -- "$TMP_ROOT"' EXIT
dir=$(make_case demo); state="$dir/state"; fakebin="$dir/fakebin"
cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
{ printf 'curl'; printf ' %s' "$@"; printf '\n'; cat; printf '\n'; } >> "$FM_FAKE_CURL_LOG"
SH
chmod +x "$fakebin/curl"
printf '%s\n' "$$" > "$state/.lock"
printf '%s on\n' "$$" > "$state/.trace-context-effective"
fm_write_meta "$state/demo-task.meta" "window=firstmate:demo-task" \
  "traceparent=00-0123456789abcdef0123456789abcdef-fedcba9876543210-01" "kind=ship" "harness=codex"
append_wake "$state" signal demo-task.status "signal: $state/demo-task.status"
append_wake "$state" heartbeat heartbeat heartbeat
append_wake "$state" check startup-network "check: startup-network still pending"
append_wake "$state" stale "firstmate:demo-task" "stale: firstmate:demo-task"
echo '### queue before presentation'; cat "$state/.wake-queue"
echo; echo '### presentation drain (stdout / stderr)'
FM_FAKE_CURL_LOG="$dir/curl.log" PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" 2> "$dir/err"; cat "$dir/err"
echo "curl calls during presentation: $( [ -f "$dir/curl.log" ] && grep -c '^curl' "$dir/curl.log" || echo 0 )"
seq=$(sed -n 's/.*--ack-through \([0-9]*\).*/\1/p' "$dir/err"); gen=$(sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/err")
sleep 2
echo; echo "### acknowledge --ack-through $seq"
FM_FAKE_CURL_LOG="$dir/curl.log" PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen"; echo "exit=$?"
echo "queue rows after ack: $(wc -l < "$state/.wake-queue" | tr -d ' ')"
echo; echo '### spans posted (one per task-keyed row; heartbeat/check/stale emit nothing)'
grep '^curl' "$dir/curl.log" | sed "s#$dir#<dir>#g"
grep -v '^curl' "$dir/curl.log" | jq '.resourceSpans[0].scopeSpans[0].spans[0] | {name, traceId, parentSpanId, startTimeUnixNano, endTimeUnixNano, attributes: [.attributes[] | {(.key): .value.stringValue}] | add}'
echo; echo '### replay of the same acknowledgement'
FM_FAKE_CURL_LOG="$dir/curl.log" PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen"; echo "exit=$?"
echo "curl calls total: $(grep -c '^curl' "$dir/curl.log")"
