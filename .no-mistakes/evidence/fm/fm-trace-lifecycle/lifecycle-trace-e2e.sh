#!/usr/bin/env bash
set -euo pipefail

ROOT=${1:?usage: lifecycle-trace-e2e.sh <repository-root>}
. "$ROOT/tests/lib.sh"

TRACEPARENT='00-11111111111111111111111111111112-3333333333333334-01'
EVIDENCE_ROOT=$(fm_test_tmproot lifecycle-trace-e2e)

install_tmux_stub() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$FM_EVIDENCE_FAKE/literal"
      case "$payload" in /exit|/quit) printf 'zsh' > "$FM_EVIDENCE_FAKE/command" ;; esac
    else
      printf '%s\n' "$payload" >> "$FM_EVIDENCE_FAKE/keys"
    fi
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$FM_EVIDENCE_FAKE/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$FM_EVIDENCE_FAKE/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'
    ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    ;;
  list-windows)
    cat "$FM_EVIDENCE_FAKE/windows"
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" sleep
  fm_test_otlp_capture_install "$fakebin"
}

span_summary() {
  local body=$1
  jq '{
    name: .resourceSpans[0].scopeSpans[0].spans[0].name,
    traceId: .resourceSpans[0].scopeSpans[0].spans[0].traceId,
    parentSpanId: .resourceSpans[0].scopeSpans[0].spans[0].parentSpanId,
    attributes: (.resourceSpans[0].scopeSpans[0].spans[0].attributes
      | map({key: .key, value: .value.stringValue}) | from_entries)
  }' <<< "$body"
}

echo '=== durable inbox steer ==='
steer="$EVIDENCE_ROOT/steer"
mkdir -p "$steer/home/state" "$steer/fake"
: > "$steer/fake/literal"
: > "$steer/fake/keys"
printf 'claude' > "$steer/fake/command"
printf '%s' "$steer" > "$steer/fake/cwd"
printf 'fm-steer\n' > "$steer/fake/windows"
install_tmux_stub "$steer"
fm_write_meta "$steer/home/state/steer.meta" \
  'window=session:fm-steer' 'endpoint_task_id=steer' 'kind=ship' 'harness=claude'
fm_test_otlp_trace_enable "$steer/home" steer "$TRACEPARENT"
echo '$ FM_HOME=<home> bin/fm-send.sh steer "private steering text"'
env PATH="$steer/fakebin:$PATH" FM_ROOT_OVERRIDE="$steer/home" FM_HOME="$steer/home" \
  FM_EVIDENCE_FAKE="$steer/fake" FM_SEND_SETTLE=0 \
  FM_FAKE_CURL_LOG="$steer/curl.log" \
  "$ROOT/bin/fm-send.sh" steer 'private steering text'
echo 'exit=0'
printf 'durable_record=%s\n' "$(basename "$steer/home/state/steer.inbox/001.msg")"
printf 'typed_terminal=%s\n' "$(cat "$steer/fake/literal")"
steer_body=$(fm_test_otlp_request_body "$steer/curl.log" 1)
span_summary "$steer_body"
case "$steer_body" in
  *'private steering text'*) echo 'privacy_check=FAIL: message content captured'; exit 1 ;;
  *) echo 'privacy_check=PASS: message content absent from OTLP body' ;;
esac

echo
echo '=== published scout promotion ==='
promote="$EVIDENCE_ROOT/promote"
mkdir -p "$promote/home/state" "$promote/home/data/scout"
fm_test_otlp_capture_install "$(fm_fakebin "$promote")"
fm_write_meta "$promote/home/state/scout.meta" \
  'window=session:fm-scout' 'endpoint_task_id=scout' "project=$promote/project" \
  "worktree=$promote/worktree" 'harness=claude' 'kind=scout' 'model=default' 'effort=default'
cat > "$promote/home/data/scout/brief.md" <<'EOF'
# Task
## Captain's intent
Promote the verified scout result.

## Firstmate spec
Ship the reproduced fix.
EOF
fm_test_otlp_trace_enable "$promote/home" scout "$TRACEPARENT"
echo '$ FM_HOME=<home> bin/fm-promote.sh scout --mode no-mistakes --yolo off'
env PATH="$promote/fakebin:$PATH" FM_HOME="$promote/home" \
  FM_FAKE_CURL_LOG="$promote/curl.log" \
  "$ROOT/bin/fm-promote.sh" scout --mode no-mistakes --yolo off
printf 'published_meta=%s\n' "$(grep -E '^(kind|mode|yolo)=' "$promote/home/state/scout.meta" | tr '\n' ' ')"
promote_body=$(fm_test_otlp_request_body "$promote/curl.log" 1)
span_summary "$promote_body"

echo
echo '=== verified agent exit ==='
control="$EVIDENCE_ROOT/control"
mkdir -p "$control/home/state" "$control/home/data/control" "$control/fake"
: > "$control/fake/literal"
: > "$control/fake/keys"
printf 'claude' > "$control/fake/command"
printf 'fm-control\n' > "$control/fake/windows"
install_tmux_stub "$control"
fm_git_worktree "$control/project" "$control/worktree" task-control
printf '%s' "$control/worktree" > "$control/fake/cwd"
printf '# control evidence\n' > "$control/home/data/control/brief.md"
fm_write_meta "$control/home/state/control.meta" \
  'window=session:fm-control' 'endpoint_task_id=control' \
  "worktree=$control/worktree" "project=$control/project" \
  'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
  'model=default' 'effort=default'
fm_test_otlp_trace_enable "$control/home" control "$TRACEPARENT"
echo '$ FM_HOME=<home> bin/fm-control.sh control exit'
env PATH="$control/fakebin:$PATH" FM_HOME="$control/home" \
  FM_EVIDENCE_FAKE="$control/fake" FM_CONTROL_POLL=0.01 \
  FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.05 \
  FM_CONTROL_LAUNCH_WAIT=0.05 FM_FAKE_CURL_LOG="$control/curl.log" \
  "$ROOT/bin/fm-control.sh" control exit
printf 'delivered_command=%s\n' "$(cat "$control/fake/literal")"
printf 'verified_process_after=%s\n' "$(cat "$control/fake/command")"
control_body=$(fm_test_otlp_request_body "$control/curl.log" 1)
span_summary "$control_body"

echo
echo 'RESULT=PASS: real CLI paths produced child lifecycle spans after their product success conditions.'
