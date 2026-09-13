#!/usr/bin/env bash
set -u
. /tmp/nm-live/spawn-helpers.sh
AMBIENT='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
drive() { # <name> <marked|primary> <ambient-value>
  local rec meta
  rec=$(make_spawn_case "$1"); read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  [ "$2" != marked ] || printf 'sm-live\n' > "$HOME_DIR/.fm-secondmate-home"
  start_trace_session "$HOME_DIR"
  echo "### $1: home=$2 ambient TRACEPARENT='$3'"
  TRACEPARENT="$3" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" --mode no-mistakes --yolo off > "$HOME_DIR/spawn.out" 2>&1; echo "rc=$?"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  echo "meta traceparent=$(meta_traceparent "$meta")"
  echo "meta trace_link=$(meta_trace_link "$meta")"
  echo "pane export TRACEPARENT=$(injected_traceparent "$LAUNCH_LOG")"
  echo "pane mentions ambient? $(grep -c 4bf92f3577b34da6a3ce929d0e0e4736 "$LAUNCH_LOG")"
}
drive sp-marked marked "$AMBIENT"
drive sp-primary primary "$AMBIENT"
drive sp-marked-bad marked '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01'
drive sp-marked-none marked ''
