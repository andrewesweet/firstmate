#!/usr/bin/env bash
# fm-nm-slot.sh - admit one no-mistakes validation start under the host's
# concurrent-validation cap.
#
# Concurrent no-mistakes validations on one machine can exhaust its memory and
# get the daemon killed mid-run. This gate is per host, not fleet-wide, and
# every firstmate home on the host shares one cap; there is deliberately no
# cross-host coordination. The mechanism: take one host-wide mutex, read
# the count of the daemon's executing runs, and only while that count is below
# the limit run the wrapped start command with the lock still held, so two
# workers cannot both see room and both start. The wrapped command must
# register its run before it returns (a bounded `--wait` start does), so the
# next caller's count includes it.
# The mutex is the same advisory lock on the same file either way: the flock
# binary where the host has it, otherwise python3's fcntl.flock, which re-execs
# this script with the locked descriptor on fd 9. python3 is already required
# for the count below, so every host takes the lock and none degrades.
#
# Every run counts that bin/fm-nm-run-lib.sh's fm_nm_run_status_class, the
# repo's owner of the daemon's status words, does not call terminal - a status
# word it does not recognise holds a slot rather than vanishing from the count -
# including a run sitting between steps, EXCEPT a run parked waiting on its
# agent at a gate and a run whose only executing step is the forge CI wait:
# neither holds the memory this cap protects, so a host of parked runs cannot
# starve every worker.
# Two ceilings, both deliberate, with no liveness or staleness machinery here:
# a parked run that is later resumed re-enters the counted set without
# re-checking the limit, and a run abandoned mid-step (its daemon killed) keeps
# its place in the count until an operator cancels it - the wait message names
# the counted run ids so that operator knows which runs hold the slots.
#
# Limit configuration (host-level, deliberately outside FM_HOME, so
# secondmate inheritance and propagation never see it):
#   ${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/nm-max-concurrent-validations
# holds one plain positive integer. Absent file means the default of 3; any
# other content refuses with a clear message instead of falling back. Size
# each host to its own RAM.
#
# The count is read from the no-mistakes daemon's own durable state store,
#   ${NM_HOME:-$HOME/.no-mistakes}/state.sqlite
# (NM_HOME is honored because the no-mistakes CLI itself honors it, and a
# relative NM_HOME resolves from the working directory as its other reader
# does). The CLI has no host-wide machine-readable run listing - its listings
# are repository-scoped - so the count is a read-only SQL query through the
# same python3 sqlite3 read-only URI reader the repo's other store reader
# uses, and rendered CLI text is never parsed. If the count cannot be read
# (python3 missing, store missing, or the query failing), this script refuses
# with the reader's own last error line, collapsed to the one line the worker
# writes into its status file, and never guesses a count; a stale store left by
# a stopped daemon can only admit a start that then fails visibly at the CLI.
#
# The lock lives at ${XDG_RUNTIME_DIR:-$HOME/.cache}/firstmate/
# nm-validation-slot.lock, outside every FM_HOME, and is held only across the
# count-then-start window; the wrapped command never inherits the lock fd.
#
# Usage:
#   fm-nm-slot.sh <command> [args...]   run <command> while holding the claimed slot
#
# Exit codes:
#   75     wait: the limit is reached, or the slot lock is busy with another start
#   78     refusal: the limit configuration or the daemon count could not be read
#   other  the wrapped command's own exit status, after admission. Both gate
#          codes are outside the range the no-mistakes CLI uses, so a failed
#          start is never read as a full slot.
set -eu

FM_NM_SLOT_WAIT=75
FM_NM_SLOT_REFUSAL=78

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_refusal() {
  printf 'error: %s\n' "$1" >&2
  exit "$FM_NM_SLOT_REFUSAL"
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
esac

[ "$#" -ge 1 ] \
  || die_refusal "usage: $(basename "$0") <command> [args...]; a slot is claimed only around a start command"

# shellcheck source=bin/fm-nm-run-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-nm-run-lib.sh"

runtime_root=${XDG_RUNTIME_DIR:-${HOME}/.cache}
config_root=${XDG_CONFIG_HOME:-${HOME}/.config}
lock_path=$runtime_root/firstmate/nm-validation-slot.lock
limit_file=$config_root/firstmate/nm-max-concurrent-validations
nm_root=${NM_HOME:-${HOME}/.no-mistakes}
case $nm_root in
  /*) ;;
  *) nm_root=$PWD/$nm_root ;;
esac
nm_db=$nm_root/state.sqlite
default_limit=3

limit=$default_limit
if [ -e "$limit_file" ]; then
  raw=$(cat "$limit_file") || die_refusal "cannot read limit configuration $limit_file"
  raw=$(fm_nm_trim "$raw")
  if [ -z "$raw" ]; then
    die_refusal "limit configuration $limit_file is empty; write one positive integer or remove the file for the default of $default_limit"
  fi
  case $raw in
    *[!0-9]*)
      die_refusal "limit configuration $limit_file must hold one plain positive integer, got '$raw'"
      ;;
  esac
  [ "${#raw}" -le 9 ] || die_refusal "limit configuration $limit_file is unreasonably large, got '$raw'"
  [ "$raw" -ge 1 ] || die_refusal "limit configuration $limit_file must be at least 1, got $raw"
  limit=$raw
fi

mkdir -p "$(dirname "$lock_path")" 2>/dev/null \
  || die_refusal "cannot create slot lock directory $(dirname "$lock_path")"

command -v python3 >/dev/null 2>&1 \
  || die_refusal "python3 is not on PATH; cannot take the host slot lock or read the no-mistakes daemon state"

if [ -z "${FM_NM_SLOT_LOCK_HELD:-}" ]; then
  if command -v flock >/dev/null 2>&1; then
    if ! { exec 9>"$lock_path"; } 2>/dev/null; then
      die_refusal "cannot open slot lock $lock_path"
    fi
    if ! flock -w 120 9; then
      echo "wait: slot lock busy at $lock_path; another validation start is in flight" >&2
      exit "$FM_NM_SLOT_WAIT"
    fi
  else
    FM_NM_SLOT_LOCK_HELD=1 exec python3 -c '
import fcntl
import os
import sys
import time

lock_path, wait_secs, wait_code = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
command = sys.argv[4:]
fd = os.open(lock_path, os.O_CREAT | os.O_WRONLY, 0o600)
deadline = time.monotonic() + wait_secs
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except OSError:
        if time.monotonic() >= deadline:
            sys.stderr.write(
                "wait: slot lock busy at %s; another validation start is in flight\n" % lock_path)
            sys.exit(wait_code)
        time.sleep(0.2)
os.dup2(fd, 9)
os.execvp(command[0], command)
' "$lock_path" 120 "$FM_NM_SLOT_WAIT" bash "$0" "$@"
  fi
fi
[ -f "$nm_db" ] \
  || die_refusal "no no-mistakes daemon state at $nm_db; is the daemon initialized on this host?"
reader_err=$(mktemp "$(dirname "$lock_path")/nm-slot-reader.XXXXXX") \
  || die_refusal "cannot create a reader error file beside $lock_path"
trap 'rm -f "$reader_err"' EXIT INT TERM

reader_error() {
  local line
  line=$(fm_nm_trim "$(grep -v '^[[:space:]]*$' "$reader_err" 2>/dev/null | tail -1)")
  [ -n "$line" ] || line="the daemon state reader failed without writing an error"
  printf '%s' "$line"
}

rows=$(fm_nm_bounded "$PWD" 30 python3 - "$nm_db" 2>"$reader_err" <<'READER'
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

with closing(sqlite3.connect(Path(sys.argv[1]).as_uri() + "?mode=ro", uri=True, timeout=30)) as db:
    db.execute("BEGIN")
    rows = db.execute(
        "SELECT r.status, count(*), group_concat(r.id, ', ') FROM runs r"
        " WHERE r.awaiting_agent_since IS NULL AND NOT ("
        "  EXISTS (SELECT 1 FROM step_results s WHERE s.run_id = r.id"
        "          AND s.status IN ('running','fixing') AND s.step_name = 'ci')"
        "  AND NOT EXISTS (SELECT 1 FROM step_results s WHERE s.run_id = r.id"
        "          AND s.status IN ('running','fixing') AND s.step_name <> 'ci'))"
        " GROUP BY r.status"
    ).fetchall()
for status, run_count, run_ids in rows:
    print("%s|%s|%s" % (status, run_count, run_ids))
READER
) || die_refusal "cannot read the no-mistakes daemon state from $nm_db: $(reader_error)"

count=0
counted_ids=''
while IFS='|' read -r status run_count run_ids extra; do
  [ -n "${status:-}${run_count:-}${run_ids:-}${extra:-}" ] || continue
  case ${run_count:-} in '' | *[!0-9]*) run_count='' ;; esac
  [ -n "${status:-}" ] && [ -n "${run_count:-}" ] && [ -n "${run_ids:-}" ] && [ -z "${extra:-}" ] \
    || die_refusal "cannot read the no-mistakes daemon state from $nm_db: unexpected reader output '$status|${run_count:-}|${run_ids:-}${extra:+|$extra}'"
  [ "$(fm_nm_run_status_class "$status")" != terminal ] || continue
  count=$((count + run_count))
  counted_ids="${counted_ids:+$counted_ids, }$run_ids"
done <<EOF
$rows
EOF

if [ "$count" -ge "$limit" ]; then
  echo "wait: $count counted no-mistakes run(s) on this host >= limit $limit; retry when one finishes. Counted runs: $counted_ids" >&2
  exit "$FM_NM_SLOT_WAIT"
fi

start_status=0
"$@" 9>&- || start_status=$?
exit "$start_status"
