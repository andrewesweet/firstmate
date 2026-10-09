#!/usr/bin/env bash
set -u
export TMPDIR="$PWD/.validation-tmp"
EV=/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH
result=0
for test in fm-project-capacity fm-spawn-dispatch-profile fm-startup-growth-check fm-timeout-lib fm-pending-reply fm-remote-reply fm-contributions fm-supervision-host fm-watch-arm fm-composer-lib fm-trace-context-spawn fm-calm-pi-extension; do
  printf 'RUN %s\n' "$test"
  rc=0
  timeout -k 5 240 bash "tests/$test.test.sh" > "$EV/$test.log" 2>&1 || rc=$?
  printf '%s exit=%s\n' "$test" "$rc" >> "$EV/targeted-results.txt"
  printf 'DONE %s exit=%s\n' "$test" "$rc"
  if [ "$rc" -ne 0 ]; then tail -n 20 "$EV/$test.log"; result=1; fi
done
exit "$result"
