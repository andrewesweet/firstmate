#!/usr/bin/env bash
# fm-spend-query.sh [--unmeasured <reason>] <task-id> - print one JSON object
# with this task's model-spend figures (bin/fm-spend-query.py owns the schema),
# resolved from the task's own record: state/<id>.meta supplies kind, harness,
# model, effort, and worktree, and the measurement window is
# [earliest spawn epoch, newest task-owned activity sidecar mtime].
# The start is spawn_epoch_first= when the record carries it (bin/fm-spawn.sh
# stamps it at the first spawn and carries it across relaunches, so a relaunched
# task still measures every incarnation), otherwise the epoch inside spawn_gen=,
# which a relaunch restamps. The end is the newest mtime among the task's own
# state sidecars (state/<id>.turn-ended, state/<id>.progress): worktrees are
# pooled and handed on the moment a worker exits, so a window that ran to now
# would price a successor task's calls as this task's. A record without either
# bound cannot be window-bounded honestly, so the answer is an explicit
# unmeasured line, never a partial or inflated figure.
# --unmeasured <reason> skips measurement and emits the schema's unmeasured
# shape for the task directly; bin/fm-teardown.sh's failed-query fallback calls
# it so the shell shape has exactly one definition (this file) beside the
# schema owner in bin/fm-spend-query.py.
# bin/fm-spend-query.py owns the schema, the runtime coverage list, and the
# assumed-rate table. Every supported runtime is either measured there or
# returns an explicit unmeasured line; a runtime whose logs cannot be parsed
# never produces a guessed figure.
# Exits 0 with the JSON on stdout when the record is readable, even on an
# unmeasured result. Exits nonzero (stderr names the reason) when the task
# record itself is missing or unreadable, or the task id is malformed - the
# caller decides what an unmeasured ledger line looks like then.
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE select the home
# (bin/fm-spawn.sh's resolution order); HOME locates the session logs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

UNMEASURED_REASON=''
case "${1:-}" in
--unmeasured)
  [ $# -ge 2 ] && [ -n "$2" ] || {
    echo "error: usage: fm-spend-query.sh --unmeasured <reason> <task-id>" >&2
    exit 2
  }
  UNMEASURED_REASON=$2
  shift 2
  ;;
-h | --help)
  usage
  exit 0
  ;;
esac
[ $# -eq 1 ] || {
  echo "error: usage: fm-spend-query.sh [--unmeasured <reason>] <task-id>" >&2
  exit 2
}

ID=$1
case "$ID" in
'' | .* | *[!A-Za-z0-9._-]*)
  echo "error: invalid task id: $ID" >&2
  exit 2
  ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in /*) ;; *) FM_HOME="$PWD/$FM_HOME" ;; esac
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
case "$STATE" in /*) ;; *) STATE="$PWD/$STATE" ;; esac

META="$STATE/$ID.meta"
[ -r "$META" ] || {
  echo "error: no readable task record for $ID at $META" >&2
  exit 2
}

meta_get() {
  sed -n "s/^$1=//p" "$META" | tail -1
}

emit_unmeasured() {  # <reason>
  jq -cn \
    --arg task "$ID" --arg kind "${KIND:-}" --arg harness "${HARNESS:-unknown}" \
    --arg model "${MODEL:-default}" --arg effort "${EFFORT:-default}" --arg reason "$1" \
    '{schema: 1, task: $task, kind: $kind, harness: $harness, model: $model, effort: $effort,
      window: null, calls: null, mean_context_tokens: null, cache_read_share: null,
      usd_lane: "unmeasured", usd: null, models: [],
      unmeasured_reason: $reason}'
}

HARNESS=$(meta_get harness)
MODEL=$(meta_get model)
EFFORT=$(meta_get effort)
KIND=$(meta_get kind)
WORKTREE=$(meta_get worktree)
SPAWN_GEN=$(meta_get spawn_gen)
SPAWN_EPOCH_FIRST=$(meta_get spawn_epoch_first)

if [ -n "$UNMEASURED_REASON" ]; then
  emit_unmeasured "$UNMEASURED_REASON"
  exit 0
fi

SPAWN_EPOCH=''
case "$SPAWN_EPOCH_FIRST" in
'' | *[!0-9]*) ;;
*) SPAWN_EPOCH=$SPAWN_EPOCH_FIRST ;;
esac
if [ -z "$SPAWN_EPOCH" ]; then
  case "$SPAWN_GEN" in
  s[0-9]*)
    SPAWN_EPOCH=$(printf '%s' "$SPAWN_GEN" | sed -n 's/^s\([0-9][0-9]*\)\..*/\1/p')
    ;;
  esac
fi
if [ -z "$SPAWN_EPOCH" ]; then
  # Without an epoch on the record the window's start cannot be bounded:
  # the record is appended to throughout the task's life, so its mtime sits
  # near the task's end, and a window that starts there would price a final
  # slice of the task's calls as the whole task. Worktrees are pooled and
  # reused, so widening the window instead would admit a successor task's
  # calls. The honest answer is the explicit unmeasured line.
  emit_unmeasured "no spawn epoch on record; session window cannot be bounded"
  exit 0
fi

END_EPOCH=''
for sidecar in "$STATE/$ID.turn-ended" "$STATE/$ID.progress"; do
  [ -e "$sidecar" ] || continue
  sidecar_mtime=$(fm_lock_path_mtime "$sidecar") || continue
  case "$sidecar_mtime" in
  '' | *[!0-9]*) continue ;;
  esac
  if [ -z "$END_EPOCH" ] || [ "$sidecar_mtime" -gt "$END_EPOCH" ]; then
    END_EPOCH=$sidecar_mtime
  fi
done
if [ -z "$END_EPOCH" ]; then
  emit_unmeasured "no task-owned activity bound available"
  exit 0
fi

# Without python3 there is no honest measurement path; emit the schema's
# unmeasured shape rather than failing (jq is already a firstmate dependency).
if ! command -v python3 >/dev/null 2>&1; then
  emit_unmeasured "python3 is unavailable, so no session log can be read"
  exit 0
fi

PY_ARGS=(--task "$ID" --kind "$KIND" --harness "${HARNESS:-unknown}"
  --model "${MODEL:-default}" --effort "${EFFORT:-default}" --worktree "$WORKTREE"
  --spawn-epoch "$SPAWN_EPOCH" --end-epoch "$END_EPOCH")

exec python3 "$SCRIPT_DIR/fm-spend-query.py" "${PY_ARGS[@]}"
