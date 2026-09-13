#!/usr/bin/env bash
# Manual end-to-end demo for PR 5 tracing: spawn (link recording), local +
# remote-style handoff spans, and the teardown root carrying the OTel span link.
# Uses the repository's own test fixtures (fake tmux / fake curl OTLP sink).
set -u
SHIM=$(cd "$(dirname "$0")/shim" && pwd)
AMBIENT='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
hr() { printf '\n===== %s =====\n' "$1"; }

hr "1. spawn inside a MARKED secondmate home with ambient TRACEPARENT=$AMBIENT"
(
  . "$SHIM/tests/spawn-helpers.sh"
  rec=$(make_spawn_case demo-sm); read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  printf 'sm-demo\n' > "$HOME_DIR/.fm-secondmate-home"
  start_trace_session "$HOME_DIR"
  TRACEPARENT="$AMBIENT" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" | tail -3
  echo "--- state/$CASE_ID.meta (trace fields):"; grep -E '^(traceparent|trace_link|trace_started)=' "$HOME_DIR/state/$CASE_ID.meta"
  echo "--- TRACEPARENT injected into the task pane:"; injected_traceparent "$LAUNCH_LOG"
  tp=$(meta_traceparent "$HOME_DIR/state/$CASE_ID.meta")
  echo "--- fresh carrier trace id != ambient trace id: $([ "${tp:3:32}" != "${AMBIENT:3:32}" ] && echo YES || echo NO)"

  hr "2. same spawn from a PRIMARY home (no marker) with the same ambient TRACEPARENT"
  rec=$(make_spawn_case demo-primary); read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"
  TRACEPARENT="$AMBIENT" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" | tail -1
  echo "--- state/$CASE_ID.meta (trace fields):"; grep -E '^(traceparent|trace_link)=' "$HOME_DIR/state/$CASE_ID.meta"
  echo "--- trace_link present? $(grep -q '^trace_link=' "$HOME_DIR/state/$CASE_ID.meta" && echo YES || echo NO)"
)

hr "3. local handoff of two backlog items to secondmate 'design' (agent carrier $(true))"
(
  . "$SHIM/tests/handoff-helpers.sh"
  home="$TMP_ROOT/demo-main"; sub="$TMP_ROOT/demo-sub"; log="$TMP_ROOT/demo-curl.log"
  setup_traced_handoff "$home" "$sub" "$log"; : > "$log"
  printf '## Queued\n- [ ] item-a - first routed item (repo: alpha)\n- [ ] item-b - second routed item (repo: alpha)\n\n## Done\n' > "$home/data/backlog.md"
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  echo "agent carrier in state/design.meta: $HANDOFF_CARRIER"
  echo '$ bin/fm-backlog-handoff.sh design item-a item-b'
  run_traced_handoff "$home" item-a item-b
  echo "--- OTLP posts captured: $(span_post_count "$log")"
  for n in 1 2; do
    echo "--- span $n:"; span_post_body "$log" "$n" | jq -c '.resourceSpans[0] | {resource: [.resource.attributes[] | select(.key|test("secondmate.id|task.kind"))], span: (.scopeSpans[0].spans[0] | {name, traceId, parentSpanId, attributes: [.attributes[] | {(.key): .value.stringValue}] | add})}'
  done
)

hr "4. teardown of a routed task in a marked secondmate home: root span carries the link"
(
  . "$SHIM/tests/teardown-helpers.sh"
  case_dir=$(make_case demo-link)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  make_traced_case "$case_dir" 'working: implementing' 'done: PR checks green'
  printf 'trace_link=%s\n' "$AMBIENT" >> "$case_dir/state/task-x1.meta"
  echo "--- state/task-x1.meta trace fields:"; grep -E '^(traceparent|trace_link)=' "$case_dir/state/task-x1.meta"
  echo '$ bin/fm-teardown.sh task-x1'
  FM_HOME="$case_dir/home" run_teardown "$case_dir" 2>&1 | tail -2
  echo "--- OTLP task root span:"; troot_body "$case_dir/curl.log" 1 | jq -c '.resourceSpans[0].scopeSpans[0].spans[0] | {name, traceId, spanId, parentSpanId, links, status}'

  hr "5. same teardown from a PRIMARY home (meta still records trace_link=): no link exported"
  case_dir=$(make_case demo-primary-teardown)
  make_traced_case "$case_dir" 'working: implementing' 'done: PR checks green'
  printf 'trace_link=%s\n' "$AMBIENT" >> "$case_dir/state/task-x1.meta"
  run_teardown "$case_dir" >/dev/null 2>&1
  troot_body "$case_dir/curl.log" 1 | jq -c '.resourceSpans[0].scopeSpans[0].spans[0] | {name, traceId, spanId, has_links: (has("links"))}'

  hr "6. telemetry stays default-off: same teardown with trace context disabled posts nothing"
  case_dir=$(make_case demo-off)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  make_traced_case "$case_dir" 'done: PR checks green'
  printf 'trace_link=%s\n' "$AMBIENT" >> "$case_dir/state/task-x1.meta"
  printf '%s off\n' "$$" > "$case_dir/state/.trace-context-effective"
  FM_HOME="$case_dir/home" run_teardown "$case_dir" >/dev/null 2>&1; echo "teardown rc=$?"
  echo "curl.log exists? $([ -f "$case_dir/curl.log" ] && echo YES || echo NO)"
)
