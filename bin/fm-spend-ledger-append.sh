#!/usr/bin/env bash
# fm-spend-ledger-append.sh [--stash] <task-id> - the shared spend-ledger producer.
# Every close path for a ship or scout task funnels through this one script, so
# a closure records its worker line no matter which path closed it: a teardown
# that lands the backlog close appends now, a teardown that retains the
# captain's call stashes a spend context (--stash) for the later answer-close
# to append from, a teardown on a home where the backlog gate does not apply
# appends now, and bin/fm-captain-hold.sh's close_answered appends now after
# every done close. Appending twice is impossible: a task the ledger already
# names prints its recorded line and appends nothing.
# Only ship and scout tasks record lines; any other kind, or a task with
# neither a readable record nor a stashed context to prove it ran a worker,
# prints nothing and exits 0. A readable record carrying no kind at all is a
# ship, the same default bin/fm-teardown.sh applies, so one owner decides a
# task's kind. A persistent secondmate retirement is out.
# The worker figure comes from bin/fm-spend-query.sh (bin/fm-spend-query.py owns
# the schema, currently version 2), falling back to that wrapper's unmeasured
# shape when the query fails, and to a minimal unmeasured object built here
# when even the wrapper cannot run - so a failed query leaves an explicit
# unmeasured line, never a missing one. The pipeline columns ride that line
# from the schema owner; this producer never recomputes them, so a line's
# pipeline figure has exactly one origin.
# The spend context (state/<id>.spend-context) carries the facts the later
# close needs after teardown removes the record: kind, harness, model, effort,
# worktree, project, branch, the window bounds, and the already-derived
# outcome. Its format is owned here; a successful append removes it.
# Best effort throughout: this script exits 0 on every path except misuse, and
# prints the appended (or already-recorded) line on stdout, or nothing when
# there is nothing to record. A failure prints one stderr line and wakes
# nobody. Callers that need the measured cost for the retrospective observer
# read it from the printed line.
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE,
# FM_CONFIG_OVERRIDE select the home (bin/fm-spawn.sh's resolution order);
# HOME locates the session logs and NM_HOME the no-mistakes inventory.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

STASH=0
case "${1:-}" in
  --stash) STASH=1; shift ;;
  -h | --help) usage; exit 0 ;;
esac
[ $# -eq 1 ] || { usage >&2; exit 2; }

ID=$1
case "$ID" in
  '' | .* | *[!A-Za-z0-9._-]*) echo "error: invalid task id: $ID" >&2; exit 2 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in /*) ;; *) FM_HOME="$PWD/$FM_HOME" ;; esac
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
case "$STATE" in /*) ;; *) STATE="$PWD/$STATE" ;; esac
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
case "$DATA" in /*) ;; *) DATA="$PWD/$DATA" ;; esac
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
case "$CONFIG" in /*) ;; *) CONFIG="$PWD/$CONFIG" ;; esac

META="$STATE/$ID.meta"
CONTEXT="$STATE/$ID.spend-context"
LEDGER="$DATA/spend-ledger.jsonl"

meta_get() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

context_get() {  # <key>
  sed -n "s/^$1=//p" "$CONTEXT" 2>/dev/null | tail -1
}

# Facts from the live record when it exists, else from the stashed context a
# retain-teardown left behind. Empty when neither proves a worker task.
KIND='' HARNESS='' MODEL='' EFFORT='' WORKTREE='' PROJECT='' BRANCH=''
MODE='' PR_URL='' SPAWN_EPOCH='' END_EPOCH='' CTX_OUTCOME='' CTX_OUTCOME_REF=''
if [ -r "$META" ]; then
  KIND=$(meta_get "$META" kind)
  [ -n "$KIND" ] || KIND=ship
  HARNESS=$(meta_get "$META" harness)
  MODEL=$(meta_get "$META" model)
  EFFORT=$(meta_get "$META" effort)
  WORKTREE=$(meta_get "$META" worktree)
  PROJECT=$(meta_get "$META" project)
  BRANCH=$(meta_get "$META" branch)
  MODE=$(meta_get "$META" mode)
  PR_URL=$(meta_get "$META" pr)
elif [ -r "$CONTEXT" ]; then
  KIND=$(context_get kind)
  HARNESS=$(context_get harness)
  MODEL=$(context_get model)
  EFFORT=$(context_get effort)
  WORKTREE=$(context_get worktree)
  PROJECT=$(context_get project)
  BRANCH=$(context_get branch)
  MODE=$(context_get mode)
  SPAWN_EPOCH=$(context_get spawn_epoch)
  END_EPOCH=$(context_get end_epoch)
  CTX_OUTCOME=$(context_get outcome)
  CTX_OUTCOME_REF=$(context_get outcome_ref)
fi

case "$KIND" in
  ship | scout) ;;
  *) exit 0 ;;
esac

window_bounds_from_record() {
  local gen first
  SPAWN_EPOCH=''
  first=$(meta_get "$META" spawn_epoch_first)
  case "$first" in '' | *[!0-9]*) ;; *) SPAWN_EPOCH=$first ;; esac
  if [ -z "$SPAWN_EPOCH" ]; then
    gen=$(meta_get "$META" spawn_gen)
    case "$gen" in
      s[0-9]*) SPAWN_EPOCH=$(printf '%s' "$gen" | sed -n 's/^s\([0-9][0-9]*\)\..*/\1/p') ;;
    esac
  fi
  END_EPOCH=''
  for sidecar in "$STATE/$ID.turn-ended" "$STATE/$ID.progress"; do
    [ -e "$sidecar" ] || continue
    sidecar_mtime=$(fm_lock_path_mtime "$sidecar") || continue
    case "$sidecar_mtime" in '' | *[!0-9]*) continue ;; esac
    if [ -z "$END_EPOCH" ] || [ "$sidecar_mtime" -gt "$END_EPOCH" ]; then
      END_EPOCH=$sidecar_mtime
    fi
  done
}

# Name what the closed task delivered, for the ledger line's outcome fields:
# the merged PR URL for a PR ship, local main for a local-only ship, the scout
# report for a scout, and nothing when a ship closed without either.
derive_outcome() {
  OUTCOME='' OUTCOME_REF=''
  if [ -n "$CTX_OUTCOME" ]; then
    OUTCOME=$CTX_OUTCOME
    OUTCOME_REF=$CTX_OUTCOME_REF
    return 0
  fi
  [ -r "$META" ] || return 0
  case "$KIND" in
    scout)
      if [ -f "$DATA/$ID/report.md" ]; then
        OUTCOME=report
        local data_rel
        data_rel=$(fm_backlog_data_relative "$DATA") || data_rel=$DATA
        OUTCOME_REF="$data_rel/$ID/report.md"
      fi
      ;;
    ship)
      if [ "$MODE" = local-only ]; then
        OUTCOME=local-main
      elif [ -n "$PR_URL" ]; then
        OUTCOME='pr'
        OUTCOME_REF=$PR_URL
      fi
      ;;
  esac
}

# A retain-teardown calls this while the record and sidecars are still in hand:
# freeze the facts the later answer-close needs after cleanup removes them.
# Idempotent: rewriting the same facts changes nothing.
if [ "$STASH" = 1 ]; then
  [ -r "$META" ] || exit 0
  window_bounds_from_record
  derive_outcome
  {
    printf 'schema=%s\n' "fm-spend-context.v1"
    printf 'task=%s\n' "$ID"
    printf 'kind=%s\n' "$KIND"
    printf 'harness=%s\n' "$HARNESS"
    printf 'model=%s\n' "$MODEL"
    printf 'effort=%s\n' "$EFFORT"
    printf 'worktree=%s\n' "$WORKTREE"
    printf 'project=%s\n' "$PROJECT"
    printf 'branch=%s\n' "$BRANCH"
    printf 'mode=%s\n' "$MODE"
    printf 'spawn_epoch=%s\n' "$SPAWN_EPOCH"
    printf 'end_epoch=%s\n' "$END_EPOCH"
    printf 'outcome=%s\n' "$OUTCOME"
    printf 'outcome_ref=%s\n' "$OUTCOME_REF"
  } > "$CONTEXT.tmp-$$" 2>/dev/null || exit 0
  chmod 0600 "$CONTEXT.tmp-$$" 2>/dev/null || { rm -f -- "$CONTEXT.tmp-$$"; exit 0; }
  mv -f -- "$CONTEXT.tmp-$$" "$CONTEXT" 2>/dev/null || { rm -f -- "$CONTEXT.tmp-$$"; exit 0; }
  exit 0
fi

derive_outcome

# The worker line: the query wrapper first (it answers unmeasured rather than
# failing whenever the record supports a window), its own unmeasured shape
# when the query fails outright, and a minimal object built here when even the
# wrapper cannot run - for example a record the wrapper cannot read, or a
# stashed context with no record left to resolve. That last resort calls the
# schema owner directly with the stashed facts, or emits the unmeasured shape
# with no measurement at all when the facts cannot bound a window.
WORKER_LINE=''
if [ -r "$META" ]; then
  WORKER_LINE=$("$SCRIPT_DIR/fm-spend-query.sh" "$ID" 2>/dev/null) || WORKER_LINE=''
  if [ -z "$WORKER_LINE" ]; then
    WORKER_LINE=$("$SCRIPT_DIR/fm-spend-query.sh" --unmeasured "spend query failed" "$ID" 2>/dev/null) || WORKER_LINE=''
  fi
fi
if [ -z "$WORKER_LINE" ] && [ -r "$CONTEXT" ] && command -v python3 >/dev/null 2>&1; then
  PY_ARGS=(--task "$ID" --kind "$KIND" --harness "${HARNESS:-unknown}"
    --model "${MODEL:-default}" --effort "${EFFORT:-default}" --worktree "$WORKTREE"
    --pipeline-branch "$BRANCH" --pipeline-project "$PROJECT")
  if [ -n "$SPAWN_EPOCH" ] && [ -n "$END_EPOCH" ]; then
    PY_ARGS+=(--spawn-epoch "$SPAWN_EPOCH" --end-epoch "$END_EPOCH")
  else
    PY_ARGS+=(--unmeasured "stashed spend context cannot bound the session window")
  fi
  WORKER_LINE=$(python3 "$SCRIPT_DIR/fm-spend-query.py" "${PY_ARGS[@]}" 2>/dev/null) || WORKER_LINE=''
fi
if [ -z "$WORKER_LINE" ]; then
  WORKER_LINE=$(jq -cn \
    --arg task "$ID" --arg kind "$KIND" --arg harness "${HARNESS:-unknown}" \
    --arg model "${MODEL:-default}" --arg effort "${EFFORT:-default}" \
    '{schema: 2, task: $task, kind: $kind, harness: $harness, model: $model, effort: $effort,
      window: null, calls: null, mean_context_tokens: null, cache_read_share: null,
      usd_lane: "unmeasured", usd: null, models: [],
      unmeasured_reason: "no spend line could be built; session window cannot be bounded",
      pipeline_runs: 0, pipeline_invocations: 0,
      pipeline_input_tokens: 0, pipeline_output_tokens: 0,
      pipeline_cache_read_tokens: 0, pipeline_cache_creation_tokens: 0,
      pipeline_agent_ms: 0, pipeline_unmeasured_invocations: 0, pipeline_unmeasured_ms: 0,
      pipeline_usd: null, pipeline_cost_lane: "unmeasured",
      pipeline_note: "pipeline not queried in the shell fallback"}' 2>/dev/null) || WORKER_LINE=''
fi
[ -n "$WORKER_LINE" ] || { echo "error: could not build $ID's spend ledger entry" >&2; exit 0; }

# The close's own fields on top of the line the schema owner built. The
# pipeline columns already ride that line, so nothing here recomputes or
# overwrites them: they enter a line in exactly one place.
MERGED=$(jq -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg outcome "$OUTCOME" \
  --arg ref "$OUTCOME_REF" \
  '. + {ts: $ts}
    + (if $outcome == "" then {} else {outcome: $outcome} end)
    + (if $ref == "" then {} else {outcome_ref: $ref} end)' \
  <<<"$WORKER_LINE" 2>/dev/null) || MERGED=''
[ -n "$MERGED" ] || { echo "error: could not build $ID's spend ledger line" >&2; exit 0; }
echo "$MERGED" | jq -e '.task == $task' --arg task "$ID" >/dev/null 2>&1 \
  || { echo "error: $ID's spend ledger line names the wrong task" >&2; exit 0; }

# The ledger write holds an exclusive lock only for the dedupe check and the
# append itself; the queries above already ran. Without flock the check and
# the append still run, because a missing line beats a perfect lock.
LOCK_FD=''
if command -v flock >/dev/null 2>&1; then
  : >> "$LEDGER" 2>/dev/null || { echo "error: spend ledger not writable at $LEDGER" >&2; exit 0; }
  # shellcheck disable=SC2094
  exec {LOCK_FD}>>"$LEDGER" 2>/dev/null || LOCK_FD=''
  if [ -n "$LOCK_FD" ]; then
    flock -x -w 10 "$LOCK_FD" 2>/dev/null || { exec {LOCK_FD}>&-; LOCK_FD=''; }
  fi
fi
EXISTING=''
if [ -f "$LEDGER" ]; then
  EXISTING=$(jq -c -n --arg task "$ID" \
    'first(inputs | select(.task == $task)) // empty' "$LEDGER" 2>/dev/null) || EXISTING=''
fi
if [ -n "$EXISTING" ]; then
  [ -n "$LOCK_FD" ] && exec {LOCK_FD}>&-
  printf '%s\n' "$EXISTING"
  rm -f -- "$CONTEXT" 2>/dev/null || true
  exit 0
fi
if ! printf '%s\n' "$MERGED" >> "$LEDGER" 2>/dev/null; then
  [ -n "$LOCK_FD" ] && exec {LOCK_FD}>&-
  echo "error: could not append $ID's spend ledger entry" >&2
  exit 0
fi
[ -n "$LOCK_FD" ] && exec {LOCK_FD}>&-
rm -f -- "$CONTEXT" 2>/dev/null || true
printf '%s\n' "$MERGED"
exit 0
