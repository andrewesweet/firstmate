#!/usr/bin/env bash
# Manual end-to-end demo: routed-task span link + firstmate.handoff span.
# Run from the worktree root. Uses a fake curl to capture OTLP bodies; no network.
set -u
ROOT=$(pwd)
. tests/secondmate-helpers.sh
. bin/fm-trace-context-lib.sh
. bin/fm-trace-span-lib.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
AGENT_TP='00-99999999999999999999999999999999-8888888888888888-01'

mkdir -p "$TMP/curlbin"
cat > "$TMP/curlbin/curl" <<SH
#!/usr/bin/env bash
cat >> '$TMP/otlp.log'; printf '\n' >> '$TMP/otlp.log'; exit 0
SH
chmod +x "$TMP/curlbin/curl"
export PATH="$TMP/curlbin:$PATH"

echo '=== 1. Link resolution: marked secondmate home vs primary home ==='
mkdir -p "$TMP/sm/config" "$TMP/sm/state" "$TMP/primary/config" "$TMP/primary/state"
printf 'design\n' > "$TMP/sm/.fm-secondmate-home"
: > "$TMP/sm/config/trace-context"; : > "$TMP/primary/config/trace-context"
export TRACEPARENT="$AGENT_TP"
echo "ambient TRACEPARENT=$TRACEPARENT"
echo "secondmate home link : '$(fm_trace_context_link_resolve "$TMP/sm")'"
echo "primary home link    : '$(fm_trace_context_link_resolve "$TMP/primary")'"
TRACEPARENT='00-$(touch /tmp/pwned)-8888888888888888-01' \
  bash -c '. bin/fm-trace-context-lib.sh; echo "malformed ambient link: '"'"'$(fm_trace_context_link_resolve "'"$TMP/sm"'")'"'"'"'
fresh=$(fm_trace_context_resolve "$TMP/sm/config" "$TMP/sm/state/w1.meta")
echo "fresh task carrier   : $fresh"
[ "${fresh:3:32}" != "${AGENT_TP:3:32}" ] && echo "carrier trace id differs from ambient: OK (never adopted)"
unset TRACEPARENT

echo; echo '=== 2. Task root span carries link (secondmate meta); child span never links ==='
cat > "$TMP/sm/state/w1.meta" <<EOF
kind=ship
project=alpha
traceparent=$fresh
trace_link=$AGENT_TP
EOF
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:1/v1/traces
printf "%s\n" "$$" > "$TMP/sm/state/.lock"; printf "%s on\n" "$$" > "$TMP/sm/state/.trace-context-effective"
: > "$TMP/otlp.log"
fm_trace_span_emit "$TMP/sm/state/w1.meta" firstmate.task 1000 2000 --root --status ok --link "$AGENT_TP" firstmate.task.outcome=done
echo '--- root span (name, traceId, parent, links):'
jq -c '.resourceSpans[0].scopeSpans[0].spans[0] | {name, traceId, parentSpanId, links}' "$TMP/otlp.log"
: > "$TMP/otlp.log"
fm_trace_span_emit "$TMP/sm/state/w1.meta" firstmate.spawn 1000 2000 --link "$AGENT_TP"
echo '--- child span given --link (links must be absent):'
jq -c '.resourceSpans[0].scopeSpans[0].spans[0] | {name, traceId, parentSpanId, links}' "$TMP/otlp.log"
: > "$TMP/otlp.log"
fm_trace_span_emit "$TMP/sm/state/w1.meta" firstmate.task 1000 2000 --root --link 'garbage'
echo '--- root span with invalid --link (links must be absent):'
jq -c '.resourceSpans[0].scopeSpans[0].spans[0] | {name, traceId, links}' "$TMP/otlp.log"

echo; echo '=== 3. Real bin/fm-backlog-handoff.sh: one firstmate.handoff span per moved key ==='
home="$TMP/main"; sub="$TMP/sub"
mkdir -p "$home/data" "$home/state"
seed_secondmate_home_marker "$sub" design
sub_abs=$(cd "$sub" && pwd -P)
printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' "$sub_abs" > "$home/data/secondmates.md"
cat > "$home/state/design.meta" <<EOF
window=firstmate:fm-design
kind=secondmate
harness=claude
backend=tmux
home=$sub_abs
worktree=$sub_abs
traceparent=$AGENT_TP
EOF
printf '%s\n' "$$" > "$home/state/.lock"
printf '%s on\n' "$$" > "$home/state/.trace-context-effective"
cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] demo-a - first routed item (repo: alpha)
- [ ] demo-b - second routed item (repo: alpha)

## Done
EOF
printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
fakebin=$(make_fake_tmux "$TMP/fake")
: > "$TMP/otlp.log"
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
  FM_FAKE_TMUX_WINDOW='firstmate:fm-design' FM_FAKE_TMUX_LOG="$TMP/tmux.log" \
  FM_FAKE_TMUX_CAPTURE="$TMP/fake/pane.txt" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
  bin/fm-backlog-handoff.sh design demo-a demo-b
echo "--- secondmate backlog after handoff:"; cat "$sub/data/backlog.md"
echo "--- OTLP posts: $(grep -c . "$TMP/otlp.log")"
jq -c '.resourceSpans[0] | {secondmate: ([.resource.attributes[] | select(.key=="firstmate.secondmate.id")][0].value.stringValue), span: (.scopeSpans[0].spans[0] | {name, traceId, parentSpanId, attrs: [.attributes[] | {(.key): .value.stringValue}] | add})}' "$TMP/otlp.log"

echo; echo '=== 4. Same handoff with tracing off: no span posted ==='
printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] demo-c - untraced item (repo: alpha)

## Done
EOF
: > "$TMP/otlp.log"
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
  FM_FAKE_TMUX_WINDOW='firstmate:fm-design' FM_FAKE_TMUX_LOG="$TMP/tmux.log" \
  FM_FAKE_TMUX_CAPTURE="$TMP/fake/pane.txt" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
  bin/fm-backlog-handoff.sh design demo-c
echo "--- OTLP posts: $(grep -c . "$TMP/otlp.log")"
