#!/usr/bin/env bash
# fm-spend-query.sh <task-id> - print one JSON object with this task's
# model-spend figures (bin/fm-spend-query.py owns the schema), resolved from
# the task's own record: state/<id>.meta supplies kind, harness, model, effort,
# and worktree, and the measurement window runs from the record's spawn time
# (the spawn_gen epoch; the meta mtime when the record predates spawn_gen) to
# now. A relaunched task measures its current incarnation: spawn_gen is
# restamped at relaunch, so earlier incarnations' records fall outside the
# window by design.
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

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac
[ $# -eq 1 ] || {
  echo "error: usage: fm-spend-query.sh <task-id>" >&2
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

HARNESS=$(meta_get harness)
MODEL=$(meta_get model)
EFFORT=$(meta_get effort)
KIND=$(meta_get kind)
WORKTREE=$(meta_get worktree)
SPAWN_GEN=$(meta_get spawn_gen)

SPAWN_EPOCH=''
case "$SPAWN_GEN" in
s[0-9]*)
  SPAWN_EPOCH=$(printf '%s' "$SPAWN_GEN" | sed -n 's/^s\([0-9][0-9]*\)\..*/\1/p')
  ;;
esac
if [ -z "$SPAWN_EPOCH" ]; then
  # Records written before spawn_gen carried the epoch: fall back to the
  # record's own mtime (GNU stat first, then BSD).
  SPAWN_EPOCH=$(stat -c %Y "$META" 2>/dev/null || stat -f %m "$META" 2>/dev/null || true)
  case "$SPAWN_EPOCH" in
    '' | *[!0-9]*) SPAWN_EPOCH='' ;;
  esac
fi

# Without python3 there is no honest measurement path; emit the schema's
# unmeasured shape rather than failing (jq is already a firstmate dependency).
if ! command -v python3 >/dev/null 2>&1; then
  jq -cn \
    --arg task "$ID" --arg kind "$KIND" --arg harness "${HARNESS:-unknown}" \
    --arg model "${MODEL:-default}" --arg effort "${EFFORT:-default}" \
    '{schema: 1, task: $task, kind: $kind, harness: $harness, model: $model, effort: $effort,
      window: null, calls: null, mean_context_tokens: null, cache_read_share: null,
      usd_lane: "unmeasured", usd: null, models: [],
      unmeasured_reason: "python3 is unavailable, so no session log can be read"}'
  exit 0
fi

PY_ARGS=(--task "$ID" --kind "$KIND" --harness "${HARNESS:-unknown}"
  --model "${MODEL:-default}" --effort "${EFFORT:-default}" --worktree "$WORKTREE")
[ -z "$SPAWN_EPOCH" ] || PY_ARGS+=(--spawn-epoch "$SPAWN_EPOCH")

exec python3 "$SCRIPT_DIR/fm-spend-query.py" "${PY_ARGS[@]}"
