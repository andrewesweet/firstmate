# shellcheck shell=bash
# bin/backends/herdr-metadata.sh - display-only Herdr pane metadata projection.
#
# This library projects exact Firstmate task records into a small bounded set
# of Herdr pane display fields through Herdr's metadata API, so an operator can
# see task/role, a concise intent, the current wait marker, and the PR or
# report pointer in the Herdr sidebar without opening the pane.
# docs/herdr-backend.md "Endpoint metadata projection" owns the field contract.
#
# Strictly display-only boundaries, all owned here:
#
# - Projection reads durable records only: the task's `.meta` record, the
#   brief's `## Captain's intent`, and `bin/fm-crew-state.sh`'s current-state
#   line. Nothing here reads Herdr metadata back into Firstmate logic.
# - Writes are bound to the task's recorded endpoint: the meta's `window=`
#   session and `herdr_pane_id` must agree, and a live `pane get` must confirm
#   the same pane id plus its recorded workspace and tab ids. Any mismatch
#   refuses the write, so a relaunched or foreign pane never receives this
#   task's labels.
# - Token names stay inside the `fm_` namespace, and every write names this
#   Firstmate home's own sequenced source id, so per-source scoping never
#   touches metadata another tool or home set.
# - Every publish is best effort: a failed write is a one-line diagnostic and a
#   nonzero return, never a failure of the caller (spawn, supervision,
#   PR registration, teardown).
#
# Sourced by bin/backends/herdr.sh; function definitions resolve at call time.

# The brief heading reader (bin/fm-brief-heading-lib.sh) is a small pure awk
# lib of idempotent function definitions; source it here so the projection owns
# its one dependency instead of assuming herdr.sh or a caller pulled it in.
if [ -n "${FM_BACKEND_HERDR_ROOT:-}" ]; then
  # shellcheck source=bin/fm-brief-heading-lib.sh
  . "$FM_BACKEND_HERDR_ROOT/bin/fm-brief-heading-lib.sh"
fi

# The sequenced source id for this Firstmate home's metadata writes.
# Deterministic per home path, so restarts keep one stable source and Herdr's
# per-source seq ordering stays meaningful across publishes.
fm_backend_herdr_metadata_source_id() {
  local home real
  home=${FM_HOME:-$PWD}
  real=$(cd "$home" 2>/dev/null && pwd -P) || real=$home
  printf 'firstmate:%s-%s' "${real##*/}" \
    "$(printf '%s' "$real" | cksum | cut -d' ' -f1 | cut -c1-8)"
}

# fm_backend_herdr_metadata_now: epoch seconds used for --seq. Overridable in
# tests so seq ordering is observable without waiting on the clock.
fm_backend_herdr_metadata_now() {
  [ -n "${FM_BACKEND_HERDR_METADATA_NOW:-}" ] && { printf '%s\n' "$FM_BACKEND_HERDR_METADATA_NOW"; return 0; }
  date +%s
}

# fm_backend_herdr_metadata_ttl_ms: how long set tokens stay before expiring if
# no later publish refreshes them. Generous by default (24h, the API max), so
# labels survive supervision gaps but cannot outlive a permanently dead
# supervisor by more than a day. Teardown clears remain the primary erasure.
fm_backend_herdr_metadata_ttl_ms() {
  printf '%s\n' "${FM_BACKEND_HERDR_METADATA_TTL_MS:-86400000}"
}

# fm_backend_herdr_metadata_clip <text> <max>: first line, whitespace
# collapsed, clipped to <max> characters so no projected field can exceed the
# API's 80-character presentation cap.
fm_backend_herdr_metadata_clip() {  # <text> <max>
  printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | cut -c"1-$2"
}

# fm_backend_herdr_metadata_intent <meta-file>: the brief's `## Captain's
# intent`, first non-empty line, clipped for title use. Task briefs live at
# data/<id>/brief.md; a local secondmate's charter is recorded as home= and
# seeds the same heading shape. An unreadable or heading-less brief degrades to
# an empty intent, never a refusal.
fm_backend_herdr_metadata_intent() {  # <meta-file>
  local data brief home line
  data=${FM_DATA_OVERRIDE:-${FM_HOME:-$PWD}/data}
  brief="$data/$(basename "$1" .meta)/brief.md"
  [ -r "$brief" ] || {
    home=$(fm_meta_get "$1" home)
    case $home in
      /*) brief="$home/data/charter.md" ;;
      *) return 0 ;;
    esac
  }
  [ -r "$brief" ] || return 0
  fm_brief_task_heading_body "$brief" "## Captain's intent" 2>/dev/null \
    | while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        [ -n "$line" ] || continue
        printf '%s\n' "$line"
        break
      done
}

# fm_backend_herdr_metadata_wait <state-line> <meta-file> [report-path]: map
# bin/fm-crew-state.sh's current state to the fm_wait marker value, or empty
# when nothing needs a marker. Herdr's own semantic agent state already shows
# native busy/blocked turns, so only the Firstmate-level waits that Herdr
# cannot see are projected: a held decision, an external wait, a ready review,
# and a finished scout report. State lines not on that list clear the marker.
fm_backend_herdr_metadata_wait() {  # <state-line> <meta-file> [report-path]
  local state_line=$1 meta=$2 report=${3:-} state detail
  state=${state_line#state: }
  case $state in
    "$state_line") return 0 ;;
  esac
  state=${state%% ·*}
  detail=${state_line#* · }
  detail=${detail#* · }
  case $detail in
    source:*|"$state_line") detail= ;;
  esac
  case $state in
    parked)
      [ -n "$detail" ] || detail=awaiting a decision
      printf 'decision: '
      fm_backend_herdr_metadata_clip "$detail" 56
      ;;
    paused)
      [ -n "$detail" ] || detail=external wait
      printf 'wait: '
      fm_backend_herdr_metadata_clip "$detail" 60
      ;;
    done)
      if [ -n "$(fm_meta_get "$meta" pr)" ]; then
        printf 'review ready'
      elif [ -n "$report" ] && [ -e "$report" ]; then
        printf 'report ready'
      fi
      ;;
  esac
}

# fm_backend_herdr_metadata_state_line <task-id>: current state from
# bin/fm-crew-state.sh, bounded to its first line. A crew-state failure is not
# a publish failure: the caller degrades to an empty state (markers cleared).
fm_backend_herdr_metadata_state_line() {  # <task-id>
  local bin
  bin=${FM_BACKEND_HERDR_METADATA_CREW_STATE_BIN:-$FM_BACKEND_HERDR_ROOT/bin/fm-crew-state.sh}
  [ -x "$bin" ] || [ -f "$bin" ] || return 1
  "$bin" "$1" 2>/dev/null | head -n 1
}

# fm_backend_herdr_metadata_binding_ok <meta-file> <session> <pane-id>: confirm
# the pane is still exactly the endpoint this task's record names. The pane get
# must find the pane, and its workspace and tab must match the recorded ids.
fm_backend_herdr_metadata_binding_ok() {  # <meta-file> <session> <pane-id>
  local meta=$1 session=$2 pane=$3 ws tab got
  ws=$(fm_meta_get "$meta" herdr_workspace_id)
  tab=$(fm_meta_get "$meta" herdr_tab_id)
  [ -n "$ws" ] && [ -n "$tab" ] || {
    printf 'metadata: %s record lacks herdr_workspace_id/herdr_tab_id; refusing an unvalidatable write\n' "$(basename "$meta" .meta)" >&2
    return 1
  }
  got=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null \
    | jq -r '.result.pane // empty | [.pane_id, .workspace_id, .tab_id] | @tsv' 2>/dev/null) || return 1
  [ -n "$got" ] || {
    printf 'metadata: pane %s not found; refusing the write\n' "$pane" >&2
    return 1
  }
  [ "$got" = "$(printf '%s\t%s\t%s' "$pane" "$ws" "$tab")" ] || {
    printf 'metadata: binding mismatch for pane %s (record wants workspace %s tab %s); refusing the write\n' "$pane" "$ws" "$tab" >&2
    return 1
  }
}

# fm_backend_herdr_metadata_publish <task-id>: project the task's records onto
# its recorded pane. Nonzero on refusal or write failure; callers decide the
# non-fatal policy (spawn/supervision detach it, teardown's clear is separate).
fm_backend_herdr_metadata_publish() {  # <task-id>
  local id=$1 state meta session pane window kind pr line now ttl src intent wait_value report tag
  local -a args=()
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$PWD}/state}
  meta=$state/$id.meta
  [ -f "$meta" ] || { printf 'metadata: no record for %s\n' "$id" >&2; return 1; }
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || return 0
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  window=$(fm_meta_get "$meta" window)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  case $window in
    *:"$pane") session=${window%%:*} ;;
    *) printf 'metadata: %s window=%s does not name pane %s; refusing\n' "$id" "$window" "$pane" >&2; return 1 ;;
  esac
  fm_backend_herdr_metadata_binding_ok "$meta" "$session" "$pane" || return 1

  kind=$(fm_meta_get "$meta" kind)
  case $kind in
    ship|scout|secondmate) ;;
    *) kind=ship ;;
  esac
  pr=$(fm_meta_get "$meta" pr)
  line=$(fm_backend_herdr_metadata_state_line "$id")
  intent=$(fm_backend_herdr_metadata_intent "$meta")
  report=${FM_DATA_OVERRIDE:-${FM_HOME:-$PWD}/data}/$id/report.md
  wait_value=$(fm_backend_herdr_metadata_wait "$line" "$meta" "$report")

  src=$(fm_backend_herdr_metadata_source_id)
  now=$(fm_backend_herdr_metadata_now)
  ttl=$(fm_backend_herdr_metadata_ttl_ms)

  args=(pane report-metadata --source "$src")
  args+=(--display-agent "firstmate $kind")
  args+=(--token "fm_task=$id")
  case $pr in
    '') args+=(--clear-token fm_pr) ;;
    *) args+=(--token "fm_pr=$pr") ;;
  esac
  if [ "$kind" = scout ] && [ -e "$report" ]; then
    args+=(--token "fm_report=data/$id/report.md")
  else
    args+=(--clear-token fm_report)
  fi
  # The title leads with the task id and closes with the intent; the wait
  # marker sits between them so the tab bar reads fm-<id>: [marker] <intent>.
  case $wait_value in
    decision:*) tag='[decision] ' ;;
    wait:*) tag='[wait] ' ;;
    'review ready') tag='[review] ' ;;
    'report ready') tag='[report] ' ;;
    *) tag= ;;
  esac
  args+=(--title "$(fm_backend_herdr_metadata_clip "fm-$id: $tag$intent" 80)")
  case $wait_value in
    '') args+=(--clear-token fm_wait) ;;
    *) args+=(--token "fm_wait=$wait_value") ;;
  esac
  args+=(--ttl-ms "$ttl")
  args+=(--seq "$now")
  args+=("$pane")
  if ! fm_backend_herdr_cli "$session" "${args[@]}"; then
    printf 'metadata: publish for %s failed (non-fatal)\n' "$id" >&2
    return 1
  fi
}

# fm_backend_herdr_metadata_clear <task-id>: erase every Firstmate-owned
# display value from the pane. Binding-validated like a publish, and only the
# fm_ namespace plus our own source's title/agent/labels are cleared, so
# concurrent foreign metadata is untouched. Pane death also erases, so a failed
# clear before a close is self-healing.
fm_backend_herdr_metadata_clear() {  # <task-id>
  local id=$1 state meta session pane window src now
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$PWD}/state}
  meta=$state/$id.meta
  [ -f "$meta" ] || return 0
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || return 0
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  window=$(fm_meta_get "$meta" window)
  pane=$(fm_meta_get "$meta" herdr_pane_id)
  case $window in
    *:"$pane") session=${window%%:*} ;;
    *) return 0 ;;
  esac
  fm_backend_herdr_metadata_binding_ok "$meta" "$session" "$pane" || return 1
  src=$(fm_backend_herdr_metadata_source_id)
  now=$(fm_backend_herdr_metadata_now)
  if ! fm_backend_herdr_cli "$session" pane report-metadata \
      --source "$src" \
      --clear-title --clear-display-agent --clear-state-labels \
      --clear-token fm_task --clear-token fm_wait --clear-token fm_pr --clear-token fm_report \
      --seq "$now" "$pane"; then
    printf 'metadata: clear for %s failed (non-fatal)\n' "$id" >&2
    return 1
  fi
}
