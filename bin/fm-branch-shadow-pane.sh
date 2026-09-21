#!/usr/bin/env bash
# fm-branch-shadow-pane.sh - bounded pane evidence for the supervision-branch
# shadow advisory trial (docs/claude-supervision-branch.md).
#
# Usage:
#   fm-branch-shadow-pane.sh <task>
#       Print one JSON line describing what the mod's own state directory and
#       the task's recorded backend endpoint still show:
#         {"task":"t1","window":"fm-t1","tail":"...","observation":
#          {"progressing":true,"seconds_since_last_activity":42,
#          "busy_source":"pi-ext"},"stale":{"series_index":3}}
#       Every field is omitted when its evidence is absent, never invented:
#       tail needs a readable pane through the recorded backend;
#       observation.progressing and busy_source need the task's busy-state
#       record (bin/fm-busy-lib.sh contract); seconds_since_last_activity
#       needs state/<task>.progress (bin/fm-busy-event.sh progress marker);
#       window is the task's recorded backend target, and stale carries the
#       watcher's own stale-series markers for that window, read read-only:
#       series_index is state/.count-<window-key> (consecutive identical-pane
#       polls) and wedge_escalations is state/.wedge-escalations-<window-key>,
#       where <window-key> is the watcher's window_key transform (bin/fm-watch.sh).
#       An unreadable endpoint or any failure with no other evidence prints
#       {"task":"<task>","unavailable":"<short cause>"} and exits 0, so the
#       shadow call simply carries no pane evidence; window and stale evidence
#       survive on their own without a tail or observation.
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

# Pane identity and the watcher's own stale-series markers for that window,
# read read-only from the watcher's marker files. The key transform mirrors
# window_key() in bin/fm-watch.sh exactly; a marker absent or mid-write prints
# nothing rather than a guessed value. These fields feed the shadow records'
# local facts only - the mod never forwards them in a request.
window=''
stale=''
key=${target//:/_}
key=${key//\//_}
key=${key//./_}
series=$(tr -d '[:space:]' <"$STATE/.count-$key" 2>/dev/null || true)
wedge=$(tr -d '[:space:]' <"$STATE/.wedge-escalations-$key" 2>/dev/null || true)
case "$series" in '' | *[!0-9]*) series='' ;; esac
case "$wedge" in '' | *[!0-9]*) wedge='' ;; esac
if [ -n "$series" ] || [ -n "$wedge" ]; then
  stale="{"
  [ -n "$series" ] && stale="${stale}\"series_index\":$series,"
  [ -n "$wedge" ] && stale="${stale}\"wedge_escalations\":$wedge,"
  stale="${stale%,}}"
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

if [ -z "$tail_text" ] && [ -z "$obs" ] && [ -z "$stale" ]; then
  printf '{"task":"%s","unavailable":"no readable pane evidence"}\n' "$task"
  exit 0
fi

out="{\"task\":\"$task\",\"window\":$(jq_json_str "$target")"
[ -n "$stale" ] && out="$out,\"stale\":$stale"
[ -n "$tail_text" ] && out="$out,\"tail\":$(jq_json_str "$tail_text")"
[ -n "$obs" ] && out="$out,\"observation\":{$(printf '%s' "$obs")}"
printf '%s}\n' "$out"
