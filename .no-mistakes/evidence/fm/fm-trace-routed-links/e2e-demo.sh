#!/usr/bin/env bash
# Manual end-to-end demo of PR 5: routed-task link + handoff spans.
# Reuses the repo's test fixtures (fake tmux / fake curl OTLP receiver) against the REAL bin/ scripts.
set -u
ROOT=$1
cd "$ROOT"
. tests/secondmate-helpers.sh
. bin/fm-trace-context-lib.sh
. bin/fm-trace-span-lib.sh
# helper functions from the spawn suite (lines before the first test_ definition)
eval "$(sed -n '15,261p' tests/fm-trace-context-spawn.test.sh)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot e2e-demo)
trap 'rm -rf "$TMP_ROOT"' EXIT

hr() { printf '\n=== %s ===\n' "$*"; }
AGENT_TP='00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01'

hr "1. Marked secondmate home: routed task spawned under ambient TRACEPARENT=$AGENT_TP"
base="$TMP_ROOT/sm"; sm="$base/home"
mkdir -p "$sm/data" "$sm/projects" "$sm/state" "$sm/config"
printf 'claude\n' > "$sm/config/crew-harness"; : > "$sm/config/trace-context"
printf 'sm-demo\n' > "$sm/.fm-secondmate-home"
touch "$sm/state/.last-watcher-beat"; start_trace_session "$sm"
fakebin=$(make_spawn_fakebin "$base/fake")
fm_git_worktree "$base/proj" "$base/wt" wt-demo
mkdir -p "$sm/data/routed-z1"; write_ship_brief "$sm/data/routed-z1/brief.md" routed-z1
TRACEPARENT="$AGENT_TP" run_spawn "$sm" "$base/wt" "$fakebin" "$base/launch.log" routed-z1 "$base/proj" | grep -i spawned
echo "--- state/routed-z1.meta (trace fields):"; grep -E '^(traceparent|trace_link|trace_started)=' "$sm/state/routed-z1.meta"
echo "--- TRACEPARENT exported into the task pane:"; grep 'export TRACEPARENT=' "$base/launch.log"
tp=$(meta_traceparent "$sm/state/routed-z1.meta")
[ "${tp:3:32}" != "${AGENT_TP:3:32}" ] && echo "CHECK: task carrier trace id differs from agent trace id (fresh trace)  OK"
[ "$(meta_trace_link "$sm/state/routed-z1.meta")" = "$AGENT_TP" ] && echo "CHECK: trace_link == ambient agent carrier  OK"

hr "2. Task root at teardown (real emitter with the recorded trace_link): OTLP body"
FM_FAKE_CURL_LOG="$base/root.curl" PATH="$fakebin:$PATH" \
  fm_trace_span_emit "$sm/state/routed-z1.meta" firstmate.task - - --root --status ok --link "$(meta_trace_link "$sm/state/routed-z1.meta")" firstmate.task.outcome=done
curl_body "$base/root.curl" 1 | jq '.resourceSpans[0].scopeSpans[0].spans[0] | {traceId, spanId, parentSpanId, name, links}'

hr "3. Relaunch after the marker is removed: carrier kept, link dropped"
rm -f "$sm/.fm-secondmate-home"
TRACEPARENT="$AGENT_TP" run_spawn "$sm" "$base/wt" "$fakebin" "$base/launch.log" routed-z1 "$base/proj" | grep -iE 'spawned|relaunch' | head -2
grep -E '^(traceparent|trace_link)=' "$sm/state/routed-z1.meta"; grep -q '^trace_link=' "$sm/state/routed-z1.meta" || echo "CHECK: no trace_link= after marker removal  OK"

hr "4. Primary home (no marker) under the same ambient TRACEPARENT: fresh carrier, no link"
rec=$(make_spawn_case primary); read_case_record "$rec"
: > "$HOME_DIR/config/trace-context"; start_trace_session "$HOME_DIR"
TRACEPARENT="$AGENT_TP" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" | grep -i spawned
grep -E '^(traceparent|trace_link)=' "$HOME_DIR/state/$CASE_ID.meta"; grep -q '^trace_link=' "$HOME_DIR/state/$CASE_ID.meta" || echo "CHECK: primary home records no trace_link=  OK"

hr "5. Default-off home: same spawn, nothing recorded"
rec=$(make_spawn_case off); read_case_record "$rec"; start_trace_session "$HOME_DIR"
printf 'sm-off\n' > "$HOME_DIR/.fm-secondmate-home"
TRACEPARENT="$AGENT_TP" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" | grep -i spawned
grep -E '^(traceparent|trace_link)=' "$HOME_DIR/state/$CASE_ID.meta" || echo "CHECK: no traceparent/trace_link recorded, $(grep -c ARGS "$LAUNCH_LOG.curl") spans posted  OK"

hr "6. Local handoff of two backlog items -> real bin/fm-backlog-handoff.sh, one firstmate.handoff span each"
if command -v tasks-axi >/dev/null; then
  home="$TMP_ROOT/h-main"; sub="$TMP_ROOT/h-sub"; log="$TMP_ROOT/h.curl"
  mkdir -p "$home/data" "$home/state"; seed_secondmate_home_marker "$sub" design
  sub_abs=$(cd "$sub" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' "$sub_abs" > "$home/data/secondmates.md"
  printf 'window=firstmate:fm-design\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\nworktree=%s\ntraceparent=%s\n' "$sub_abs" "$sub_abs" "$AGENT_TP" > "$home/state/design.meta"
  printf '%s\n' "$$" > "$home/state/.lock"; printf '%s on\n' "$$" > "$home/state/.trace-context-effective"
  mkdir -p "$home/span-curl"; printf '#!/usr/bin/env bash\n{ printf "ARGS:"; printf " <%%s>" "$@"; printf "\\n"; cat; printf "\\n--BODY-END--\\n"; } >> "%s"\nexit 0\n' "$log" > "$home/span-curl/curl"; chmod +x "$home/span-curl/curl"
  printf '## Queued\n- [ ] item-a - first routed item (repo: alpha)\n- [ ] item-b - second routed item (repo: alpha)\n\n## Done\n' > "$home/data/backlog.md"
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  hb=$(make_fake_tmux "$TMP_ROOT/h-fake")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$home/span-curl:$hb:$PATH" FM_FAKE_TMUX_WINDOW='firstmate:fm-design' \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/h-tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/h-fake/pane.txt" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
    bin/fm-backlog-handoff.sh design item-a item-b
  echo "--- secondmate backlog now:"; cat "$sub/data/backlog.md"
  echo "--- OTLP posts: $(grep -c '^ARGS:' "$log")"
  for n in 1 2; do curl_body "$log" $n | jq -c '.resourceSpans[0] | {resource: [.resource.attributes[] | select(.key|test("secondmate.id|task.kind"))], span: (.scopeSpans[0].spans[0] | {traceId, parentSpanId, name, attributes: [.attributes[] | {(.key): .value.stringValue}] | add})}'; done
else
  echo "tasks-axi missing: skipped"
fi
