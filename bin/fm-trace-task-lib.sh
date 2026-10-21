# shellcheck shell=bash
# Task metadata and home-routing integration for trace context.
# Sourced by fm-trace-context-lib.sh to retain its public entry points; that
# library's header owns the resource-attribute and routing-link contracts.

# fm_root_is_secondmate_home is the one definition of "marked secondmate home"
# firstmate has; the link boundary below reuses it rather than restating it.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-primary-scope-lib.sh"

# Public entry point. Echo the ambient TRACEPARENT to record as a routed
# task's span link, or nothing. Always returns 0 so a link decision is
# omitted safely and never aborts the spawn. The marked-secondmate-home gate
# (fm_root_is_secondmate_home, the same predicate every other firstmate hook
# uses) comes FIRST so a primary home never reads ambient context at all, then the
# strict W3C validator decides over the raw environment value; neither the
# marker id nor any other file content influences the echoed bytes.
fm_trace_context_link_resolve() {  # <home>
  local home=$1
  [ -n "$home" ] || return 0
  fm_root_is_secondmate_home "$home" || return 0
  [ -n "${TRACEPARENT:-}" ] || return 0
  fm_trace_context_valid "$TRACEPARENT" || return 0
  printf '%s' "$TRACEPARENT"
}

# --- per-task resource attributes (OTEL_RESOURCE_ATTRIBUTES) -----------------

# Echo <value> with every byte outside [A-Za-z0-9._-/] replaced by its %XX
# form (W3C Baggage rules). Byte-oriented under LC_ALL=C, so multi-byte
# characters encode as one %XX pair per byte, and the output always matches
# [A-Za-z0-9._%/-]* - one safe comma-joined token when keys are prefixed.
fm_trace_attrs_percent_encode() {  # <value>
  local value=$1 out='' ch hex i
  local LC_ALL=C
  for ((i = 0; i < ${#value}; i++)); do
    ch=${value:i:1}
    case "$ch" in
      [-A-Za-z0-9._/]) out+=$ch ;;
      *)
        printf -v hex '%%%02X' "'$ch" || return 1
        out+=$hex
        ;;
    esac
  done
  printf '%s' "$out"
}

# Echo the value of one key=value line in <meta-file>, or nothing when the
# line is absent. Keys are fixed firstmate slugs, so the pattern is literal.
fm_trace_attrs_meta_value() {  # <meta-file> <key>
  local line
  line=$(grep "^$2=" "$1" 2>/dev/null | head -n1) || return 0
  printf '%s' "${line#"$2="}"
}

# Public entry point. Echo one OTEL_RESOURCE_ATTRIBUTES value (the fixed key
# list owned by fm-trace-context-lib.sh's header, in that order) from <meta-file>,
# or nothing when the meta is absent or carries no task id. Always returns 0:
# an attribute decision is omitted safely and never aborts the spawn. Values
# derive only from the task meta and, for a routed task inside a secondmate
# home, the spawning home's .fm-secondmate-home marker - never from task
# prose or a prompt (FM_HOME selects the marker location).
fm_trace_attrs_render() {  # <meta-file>
  local meta=$1
  local task_id project home_dir kind harness model effort spawn_gen
  local secondmate_id='' marker_home=${FM_HOME:-} marker_id=''
  [ -f "$meta" ] || return 0
  task_id=$(fm_trace_attrs_meta_value "$meta" endpoint_task_id)
  project=$(fm_trace_attrs_meta_value "$meta" project)
  home_dir=$(fm_trace_attrs_meta_value "$meta" home)
  kind=$(fm_trace_attrs_meta_value "$meta" kind)
  harness=$(fm_trace_attrs_meta_value "$meta" harness)
  model=$(fm_trace_attrs_meta_value "$meta" model)
  effort=$(fm_trace_attrs_meta_value "$meta" effort)
  spawn_gen=$(fm_trace_attrs_meta_value "$meta" spawn_gen)
  [ -n "$task_id" ] || return 0
  project=${project##*/}
  if [ "$kind" = secondmate ]; then
    secondmate_id=$task_id
  elif [ -n "$marker_home" ] && [ -f "$marker_home/.fm-secondmate-home" ] \
    && [ ! -L "$marker_home/.fm-secondmate-home" ]; then
    marker_id=$(head -n1 "$marker_home/.fm-secondmate-home" 2>/dev/null) || marker_id=''
    secondmate_id=$marker_id
  fi
  local out
  out="firstmate.task.id=$(fm_trace_attrs_percent_encode "$task_id")"
  out+=",firstmate.project=$(fm_trace_attrs_percent_encode "$project")"
  out+=",firstmate.home=$(fm_trace_attrs_percent_encode "$home_dir")"
  out+=",firstmate.task.kind=$(fm_trace_attrs_percent_encode "$kind")"
  out+=",firstmate.harness=$(fm_trace_attrs_percent_encode "$harness")"
  out+=",firstmate.model=$(fm_trace_attrs_percent_encode "$model")"
  out+=",firstmate.effort=$(fm_trace_attrs_percent_encode "$effort")"
  out+=",firstmate.spawn_gen=$(fm_trace_attrs_percent_encode "$spawn_gen")"
  [ -z "$secondmate_id" ] \
    || out+=",firstmate.secondmate.id=$(fm_trace_attrs_percent_encode "$secondmate_id")"
  printf '%s' "$out"
}
