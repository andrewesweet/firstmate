#!/usr/bin/env bash
# Evidence driver: reuses the suites' own fixtures (test files sourced with
# their dispatch lines stripped) to run real bin/fm-spawn.sh, bin/fm-teardown.sh
# and bin/fm-backlog-handoff.sh scenarios and dump the user-visible outputs
# (task meta records, OTLP span payloads) into the evidence directory.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
REPO=$1
SCENARIO=$2
libify() { sed -e "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$REPO/tests#g" -e '/^test_[a-z0-9_]*$/d' -e '/^echo "# all /d' -e '/^echo "ALL TESTS PASSED"/d' "$REPO/tests/$1" > "/tmp/ev-lib-$1"; printf '/tmp/ev-lib-%s' "$1"; }

case $SCENARIO in
spawn)
  . "$(libify fm-trace-context-spawn.test.sh)"
  OUT="$EV/01-spawn-link.md"
  sm_tp='00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01'
  base="$TMP_ROOT/ev"; sm="$base/sm-home"
  mkdir -p "$sm/data" "$sm/projects" "$sm/state" "$sm/config"
  printf 'claude\n' > "$sm/config/crew-harness"; : > "$sm/config/trace-context"
  printf 'sm-routed\n' > "$sm/.fm-secondmate-home"
  printf '%s\n' "$$" > "$sm/state/.lock"; touch "$sm/state/.last-watcher-beat"
  start_trace_session "$sm"
  fakebin=$(make_spawn_fakebin "$base/fake")
  fm_git_worktree "$base/proj-a" "$base/wt-a" wt-a
  mkdir -p "$sm/data/routed-a-z1"; write_ship_brief "$sm/data/routed-a-z1/brief.md" routed-a-z1
  {
    echo '# Scenario 1: routed task spawned inside a marked secondmate home'
    echo; echo "Ambient TRACEPARENT in the agent pane shell: \`$sm_tp\`"
    echo; echo '```console'
    echo '$ cat sm-home/.fm-secondmate-home'; cat "$sm/.fm-secondmate-home"
    echo '$ TRACEPARENT=$sm_tp bin/fm-spawn.sh routed-a-z1 <proj> --mode no-mistakes --yolo off'
    TRACEPARENT="$sm_tp" run_spawn "$sm" "$base/wt-a" "$fakebin" "$base/launch-a.log" routed-a-z1 "$base/proj-a"; echo "exit=$?"
    echo '$ grep -E "^(traceparent|trace_started|trace_link)=" sm-home/state/routed-a-z1.meta'
    grep -E '^(traceparent|trace_started|trace_link)=' "$sm/state/routed-a-z1.meta"
    echo '$ grep TRACEPARENT launch-a.log   # what the task pane actually receives'
    grep TRACEPARENT "$base/launch-a.log"
    echo '```'
    echo; echo 'Observed: fresh carrier (different trace id from the ambient value), ambient value recorded only as `trace_link=`, pane receives the fresh carrier.'
    echo; echo '## Relaunch keeps carrier and link'
    echo '```console'
    echo '$ TRACEPARENT=$sm_tp bin/fm-spawn.sh routed-a-z1 <proj> ...   # same id again (recovery relaunch)'
    TRACEPARENT="$sm_tp" run_spawn "$sm" "$base/wt-a" "$fakebin" "$base/launch-a.log" routed-a-z1 "$base/proj-a" | tail -1
    grep -E '^(traceparent|trace_link)=' "$sm/state/routed-a-z1.meta"
    echo '```'
    echo; echo '## Marker removed: relaunch drops the link (home now primary)'
    echo '```console'
    echo '$ rm sm-home/.fm-secondmate-home; TRACEPARENT=$sm_tp bin/fm-spawn.sh routed-a-z1 <proj> ...'
    rm -f "$sm/.fm-secondmate-home"
    TRACEPARENT="$sm_tp" run_spawn "$sm" "$base/wt-a" "$fakebin" "$base/launch-a.log" routed-a-z1 "$base/proj-a" | tail -1
    echo '$ grep -E "^(traceparent|trace_link)=" sm-home/state/routed-a-z1.meta'
    grep -E '^(traceparent|trace_link)=' "$sm/state/routed-a-z1.meta"; echo "(trace_link lines: $(grep -c '^trace_link=' "$sm/state/routed-a-z1.meta"))"
    echo '```'
    echo; echo '# Scenario 2: primary home (no marker) under the same ambient TRACEPARENT'
    rec=$(make_spawn_case ev-primary); read_case_record "$rec"
    : > "$HOME_DIR/config/trace-context"; start_trace_session "$HOME_DIR"
    echo '```console'
    echo '$ ls primary-home/.fm-secondmate-home'; ls "$HOME_DIR/.fm-secondmate-home" 2>&1 | sed 's#.*/\.fm#.fm#'
    echo "\$ TRACEPARENT=$sm_tp bin/fm-spawn.sh $CASE_ID <proj> --mode no-mistakes --yolo off"
    TRACEPARENT="$sm_tp" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" | tail -1
    echo "\$ grep -E '^(traceparent|trace_link)=' state/$CASE_ID.meta"
    grep -E '^(traceparent|trace_link)=' "$HOME_DIR/state/$CASE_ID.meta"; echo "(trace_link lines: $(grep -c '^trace_link=' "$HOME_DIR/state/$CASE_ID.meta"))"
    echo '```'
    echo; echo '# Scenario 3: default-off home (no config/trace-context)'
    rec=$(make_spawn_case ev-off); read_case_record "$rec"
    printf 'sm-off\n' > "$HOME_DIR/.fm-secondmate-home"; start_trace_session "$HOME_DIR"
    echo '```console'
    TRACEPARENT="$sm_tp" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" | tail -1
    echo "\$ grep -cE '^(traceparent|trace_link)=' state/$CASE_ID.meta"; grep -cE '^(traceparent|trace_link)=' "$HOME_DIR/state/$CASE_ID.meta"
    echo "\$ span posts recorded: $(span_request_count "$LAUNCH_LOG.curl")"
    echo '```'
  } > "$OUT" 2>&1
  ;;
teardown)
  . "$(libify fm-teardown.test.sh)"
  OUT="$EV/02-teardown-root-link.md"
  link='00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01'
  {
    echo '# Teardown: task root span carries the recorded trace_link as an OTel span link'
    echo; echo '## Marked secondmate home'
    case_dir=$(make_case ev-link)
    configure_secondmate_home "$case_dir" local "$case_dir/parent"
    make_traced_case "$case_dir" 'working: implementing' 'done: PR checks green'
    printf 'trace_link=%s\n' "$link" >> "$case_dir/state/task-x1.meta"
    echo '```console'; echo '$ grep -E "^(traceparent|trace_link)=" state/task-x1.meta'
    grep -E '^(traceparent|trace_link)=' "$case_dir/state/task-x1.meta"
    echo '$ bin/fm-teardown.sh task-x1'
    FM_HOME="$case_dir/home" run_teardown "$case_dir" 2>&1 | tail -2; echo "exit=$?"
    echo '$ # OTLP body posted by the emitter (span only):'
    troot_body "$case_dir/curl.log" 1 | jq '.resourceSpans[0].scopeSpans[0].spans[0] | {name,traceId,spanId,parentSpanId,links,status}'
    echo '```'
    echo; echo '## Primary home, same meta (no marker): no link exported'
    case_dir=$(make_case ev-primary)
    make_traced_case "$case_dir" 'working: implementing' 'done: PR checks green'
    printf 'trace_link=%s\n' "$link" >> "$case_dir/state/task-x1.meta"
    mkdir -p "$case_dir/home"
    echo '```console'
    FM_HOME="$case_dir/home" run_teardown "$case_dir" 2>&1 | tail -1; echo "exit=$?"
    troot_body "$case_dir/curl.log" 1 | jq -c '.resourceSpans[0].scopeSpans[0].spans[0] | {name,traceId,links:(.links // "absent")}'
    echo '```'
  } > "$OUT" 2>&1
  ;;
handoff)
  . "$(libify fm-backlog-handoff.test.sh)"
  OUT="$EV/03-handoff-local-spans.md"
  home="$TMP_ROOT/ev-main" sub="$TMP_ROOT/ev-sub" log="$TMP_ROOT/ev-curl.log"
  setup_traced_handoff "$home" "$sub" "$log"; : > "$log"
  printf '## Queued\n- [ ] span-a - first routed item (repo: alpha)\n- [ ] span-b - second routed item (repo: alpha)\n\n## Done\n' > "$home/data/backlog.md"
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
  {
    echo '# Local handoff: one firstmate.handoff span per moved key'
    echo; echo '```console'
    echo '$ grep ^traceparent= state/design.meta   # secondmate agent carrier'; grep '^traceparent=' "$home/state/design.meta"
    echo '$ bin/fm-backlog-handoff.sh design span-a span-b'
    run_traced_handoff "$home" span-a span-b 2>&1; echo "exit=$?"
    echo "\$ # firstmate.handoff spans posted: $(span_post_count "$log")"
    n=1; while read -r b; do echo "--- span $n"; jq '.resourceSpans[0].scopeSpans[0].spans[0] | {name,traceId,parentSpanId,attributes:[.attributes[]|{(.key):.value.stringValue}]|add}' <<< "$b"; n=$((n+1)); done < <(span_post_bodies "$log")
    echo '--- resource attributes of span 1'
    span_post_body "$log" 1 | jq -c '[.resourceSpans[0].resource.attributes[]|{(.key):.value.stringValue}]|add'
    echo '```'
    echo; echo '## Default-off home: same handoff, no span'
    home2="$TMP_ROOT/ev-off-main" sub2="$TMP_ROOT/ev-off-sub" log2="$TMP_ROOT/ev-off-curl.log"
    setup_traced_handoff "$home2" "$sub2" "$log2" off; : > "$log2"
    printf '## Queued\n- [ ] off-a - item (repo: alpha)\n\n## Done\n' > "$home2/data/backlog.md"
    printf '## Queued\n\n## Done\n' > "$sub2/data/backlog.md"
    echo '```console'; run_traced_handoff "$home2" off-a 2>&1 | head -1
    echo "\$ # firstmate.handoff spans posted: $(span_post_count "$log2")"; echo '```'
  } > "$OUT" 2>&1
  ;;
esac
echo "wrote $OUT"
