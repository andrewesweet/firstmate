#!/usr/bin/env bash
set -u
. /tmp/nm-live/teardown-helpers.sh
LINK='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
drive() { # <name> <secondmate|primary> <link-value>
  local name=$1 kind=$2 link=$3 case_dir rc
  case_dir=$(make_case "$name")
  [ "$kind" != secondmate ] || configure_secondmate_home "$case_dir" local "$case_dir/parent"
  make_traced_case "$case_dir" 'working: implementing' 'done: PR checks green'
  [ -z "$link" ] || printf 'trace_link=%s\n' "$link" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/fakebin/curl"   # real curl, real collector
  echo "### $name: kind=$kind marker=$([ -f "$case_dir/home/.fm-secondmate-home" ] && echo present || echo absent) trace_link='$link'"
  echo "### meta before teardown:"; grep -E '^(traceparent|trace_link)=' "$case_dir/state/task-x1.meta"
  set +e
  if [ "$kind" = secondmate ]; then FM_HOME="$case_dir/home" OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:47318 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  else OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:47318 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"; fi
  rc=$?; set -e
  echo "### teardown rc=$rc; stdout: $(head -3 "$case_dir/stdout" | tr '\n' '|')"
}
drive td-secondmate-link secondmate "$LINK"
drive td-primary-link primary "$LINK"
drive td-secondmate-badlink secondmate 'not-a-traceparent'
