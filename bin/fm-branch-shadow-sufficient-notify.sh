#!/usr/bin/env bash
# fm-branch-shadow-sufficient-notify.sh - the deterministic action half of a
# supervision-branch shadow-trial sufficiency watch (docs/claude-supervision-
# branch.md, "Shadow advisory trial"): append exactly ONE durable `check` wake
# naming the gates the watch found evaluable, so the next drain presents the
# evidence and the held follow-ups can be judged. Nothing else: no scoring, no
# lifecycle action, no judgment - the scorer owns the verdict, and the
# when-watch's fired marker guarantees this runs at most once per arming.
#
# Usage:
#   fm-branch-shadow-sufficient-notify.sh <gate>[,<gate>...] <bound> [<wake-key>]
#
# <gate>[,<gate>...]  the gate names the watch's condition judged sufficient
# <bound>             the bound the condition ran with, for the wake payload
# <wake-key>          optional durable wake key (default shadow-sufficient);
#                     use one distinct slug per armed bound so two watches
#                     firing between drains never dedupe to one presentation
#
# Exit 0 when the wake is appended; nonzero on invalid arguments or a failed
# append, so a broken action surfaces as action-failed, never as silence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

GATES=${1:-}
BOUND=${2:-}
KEY=${3:-shadow-sufficient}

[ -n "$GATES" ] || { echo "fm-branch-shadow-sufficient-notify: the gate list is required" >&2; exit 2; }
[ -n "$BOUND" ] || { echo "fm-branch-shadow-sufficient-notify: the bound is required" >&2; exit 2; }
case "$KEY" in '' | *[!A-Za-z0-9._-]*)
  echo "fm-branch-shadow-sufficient-notify: the wake key must be path-safe: $KEY" >&2
  exit 2
  ;;
esac
case "$BOUND" in '' | *[!0-9.]*)
  echo "fm-branch-shadow-sufficient-notify: the bound must be a number in (0,1]: $BOUND" >&2
  exit 2
  ;;
esac
awk -v b="$BOUND" 'BEGIN { exit !(b + 0 > 0 && b + 0 <= 1) }' || {
  echo "fm-branch-shadow-sufficient-notify: the bound must be in (0,1]: $BOUND" >&2
  exit 2
}
gl=
for g in $(printf '%s' "$GATES" | tr ',' ' '); do
  [ -n "$g" ] || continue
  gl="$gl $g"
done
[ -n "$gl" ] || { echo "fm-branch-shadow-sufficient-notify: the gate list is empty: $GATES" >&2; exit 2; }

fm_wake_append check "$KEY" \
  "check: shadow advisory trial gate sufficiency reached at bound $BOUND for$gl - score bin/fm-branch-shadow-gates.sh and judge the held follow-ups"
