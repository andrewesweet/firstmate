#!/usr/bin/env bash
# fm-branch-shadow-pane.sh - bounded pane evidence for the Claude Code
# supervision-branch mod's shadow advisory trial (docs/claude-supervision-branch.md).
#
# Usage:
#   fm-branch-shadow-pane.sh <task>
#       Print one JSON line describing what the mod's own state directory and
#       the task's recorded backend endpoint still show:
#         {"task":"t1","tail":"...","observation":{"progressing":true,
#          "seconds_since_last_activity":42,"busy_source":"pi-ext"}}
#       Every field is omitted when its evidence is absent, never invented:
#       tail needs a readable pane through the recorded backend;
#       observation.progressing and busy_source need the task's busy-state
#       record (bin/fm-busy-lib.sh contract); seconds_since_last_activity
#       needs state/<task>.progress (bin/fm-busy-event.sh progress marker).
#       An unreadable endpoint or any failure prints
#       {"task":"<task>","unavailable":"<short cause>"} and exits 0, so the
#       shadow call simply carries no pane evidence.
#
# Read-only: this script writes nothing. Like every bin/ piece the mod relies
# on it is inert without state/.branch-mod-mode, and the tail is bounded to
# the last 40 lines / 6000 characters; the caller bounds the whole helper with
# its own process timeout.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
_fm_wake_require_classify

task=${1:-}
case "$task" in
  '' | *[!A-Za-z0-9._-]*)
    echo "usage: fm-branch-shadow-pane.sh <task>" >&2
    exit 2
    ;;
esac

# Defense-in-depth gate: only the shadow advisory under state/.branch-mod-mode
# calls this helper, and it prints nothing when the mod is not switched on.
[ -f "$STATE/.branch-mod-mode" ] || exit 1

jq_json_str() {  # <text>: one JSON string literal, empty-safe
  printf '%s' "$1" | jq -R -s .
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

meta="$STATE/$task.meta"
[ -f "$meta" ] || { printf '{"task":"%s","unavailable":"no task meta"}\n' "$task"; exit 0; }
backend=$(fm_backend_of_meta "$meta")
target=$(fm_backend_target_of_meta "$meta")
if [ -z "$target" ]; then
  printf '{"task":"%s","unavailable":"no backend target in meta"}\n' "$task"
  exit 0
fi

# Bounded tail through the recorded backend; a failed or unsupported capture
# simply drops the field. The caller's process timeout bounds the capture.
tail_text=''
tail_raw=$(fm_backend_capture "$backend" "$target" 40 "fm-$task" 2>/dev/null) || tail_raw=''
if [ -n "$tail_raw" ]; then
  tail_text=$(printf '%s' "$tail_raw" | tail -c 6000)
fi

# Structured observation from the state the mod's home already holds.
now=$(date +%s)
obs=''
busy_rec="$STATE/$task.busy-state"
if [ -f "$busy_rec" ]; then
  # Record format (bin/fm-busy-lib.sh): v1 gen=<t> seq=<n> state=<s> source=<src> event=<e> ts=<epoch>
  bstate=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^state=/) {sub(/^state=/,"",$i); print $i}}' "$busy_rec")
  bsource=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^source=/) {sub(/^source=/,"",$i); print $i}}' "$busy_rec")
  case "$bstate" in
    busy) obs=$(printf '%s%s' "$obs" '"progressing":true,' ) ;;
    idle) obs=$(printf '%s%s' "$obs" '"progressing":false,') ;;
  esac
  [ -n "$bsource" ] && obs=$(printf '%s"busy_source":%s,' "$obs" "$(jq_json_str "$bsource")")
fi
prog="$STATE/$task.progress"
if [ -f "$prog" ]; then
  mtime=$(stat -c %Y "$prog" 2>/dev/null || stat -f %m "$prog" 2>/dev/null || echo '')
  case "$mtime" in
    '' | *[!0-9]*) : ;;
    *) obs=$(printf '%s"seconds_since_last_activity":%d,' "$obs" $((now > mtime ? now - mtime : 0))) ;;
  esac
fi
obs=${obs%,}

if [ -z "$tail_text" ] && [ -z "$obs" ]; then
  printf '{"task":"%s","unavailable":"no readable pane evidence"}\n' "$task"
  exit 0
fi

out="{\"task\":\"$task\""
[ -n "$tail_text" ] && out="$out,\"tail\":$(jq_json_str "$tail_text")"
[ -n "$obs" ] && out="$out,\"observation\":{$(printf '%s' "$obs")}"
printf '%s}\n' "$out"
