# shellcheck shell=bash
# Native W3C trace-context propagation for firstmate spawns (default-off).
#
# When enabled, firstmate resolves one W3C `traceparent` carrier for a task,
# injects it into the agent's pane shell as the TRACEPARENT environment variable
# before launch (bin/fm-spawn.sh, alongside GOTMPDIR, so it reaches every spawn
# backend and every harness for ship, scout, and secondmate spawns), and records
# the identical value as `traceparent=` in state/<id>.meta. Because the injected
# carrier and the recorded carrier are the same string, an observer that reads
# the metadata sees exactly the identity the child received - no collector,
# storage, UI, or vendor coupling. The same enabled path also exports one
# OTEL_RESOURCE_ATTRIBUTES value into the pane immediately after TRACEPARENT,
# rendered from the task's own metadata, so harnesses that join by resource
# attributes rather than by parenting still carry the per-task join keys.
#
# TRACEPARENT here is a firstmate CONVENTION that carries a W3C-formatted
# traceparent value in the process environment. W3C Trace Context standardizes
# the `traceparent` HTTP header, not an environment variable, and OpenTelemetry
# SDKs do NOT read TRACEPARENT from the environment automatically. A downstream
# observer or instrumentation must explicitly read this env value (or the meta
# field); this library parents no SDK span by itself.
#
# Identity is per TASK, and each task is its own trace boundary: the carrier is
# minted as a fresh random root on the task's first spawn and REUSED verbatim
# from the meta on relaunch/recovery, so a task keeps one stable logical
# identity across restarts. The spawning process's own ambient TRACEPARENT is
# the agent identity it received at ITS launch, never a parent for new tasks: a
# persistent supervisor routes many unrelated tasks from one long-lived
# environment, and adopting its carrier would merge every routed task into one
# ever-growing trace instead of one trace per task.
#
# Usage: . bin/fm-trace-context-lib.sh
#
# Public entry points:
#   fm_trace_attrs_render <meta-file>
#     Echoes one OTEL_RESOURCE_ATTRIBUTES value rendered from the task meta
#     file, or nothing when the meta is absent or carries no task id. Always
#     returns 0: the attribute export is omitted safely and never aborts the
#     spawn.
#   fm_trace_context_session_start <config-dir> <effective-state-file>
#     Resolves config/trace-context plus FM_TRACE_CONTEXT once and atomically
#     writes the normalized on/off decision bound to the locked home session.
#   fm_trace_context_session_effective <effective-state-file>
#     Echoes the normalized frozen decision only when its session binding matches
#     the current lock, defaulting to off when the state is absent, stale, or invalid.
#   fm_trace_context_resolve <config-dir> <meta-file>
#     Echoes the traceparent to inject AND record, or nothing when the
#     capability is off or when entropy or self-validation fails. It ALWAYS
#     returns 0: telemetry is omitted safely and never aborts the spawn. The
#     task's recorded carrier wins so recovery keeps identity; otherwise a
#     fresh root is minted, never derived from this process's environment.
#
# Enablement (see docs/configuration.md for the schema):
#   config/trace-context   presence flag under the home's config dir enables it.
#   FM_TRACE_CONTEXT        env override: 1/on/true/yes enables, any other
#                           non-empty value disables, and unset OR empty defers
#                           to the file.
#   Each locked home session resolves these inputs once into
#   state/.trace-context-effective. The record is atomically published through a
#   same-directory temporary file and bound to state/.lock; a failed publication
#   cannot reactivate a stale on decision. Every spawn reads only that frozen
#   on/off value, so later config and environment edits take effect only after a
#   new home session starts.
#   At launch, the primary propagates config/trace-context into the secondmate
#   home (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh) and passes its
#   frozen on/off decision into the new process as a non-empty FM_TRACE_CONTEXT
#   value in the launch prefix (bin/fm-spawn.sh). The Secondmate freezes that
#   inherited decision when its own home session starts.
#   A REMOTE secondmate route resolves here too, in the PARENT process that owns
#   that task's meta: fm-spawn's spawn_remote_secondmate resolves the carrier,
#   hands it to the configured host through fm-spawn's --traceparent, and records
#   the carrier the remote endpoint reports back. Only the pane export moves
#   hosts; identity, enablement, and the per-task boundary do not.
#
# Resource-attribute keys (in render order; this header is the list's owner).
# Values are percent-encoded per the W3C Baggage rules the Claude Code
# monitoring doc restates: anything outside [A-Za-z0-9._-/] becomes %XX, so the
# rendered value is one comma-joined token free of shell metacharacters.
#   firstmate.task.id        the task id (meta endpoint_task_id)
#   firstmate.project        basename of the meta project directory
#   firstmate.home           the meta home directory; the project directory's
#                            parent when the meta carries no home field
#   firstmate.task.kind      ship | scout | secondmate (meta kind)
#   firstmate.harness        the launch harness (meta harness)
#   firstmate.model          the launch model (meta model; may be empty)
#   firstmate.effort         the launch effort (meta effort; may be empty)
#   firstmate.spawn_gen      the incarnation token (meta spawn_gen)
#   firstmate.secondmate.id  present ONLY for a secondmate: the agent's own
#                            task id when the meta kind is secondmate, else the
#                            spawning home's .fm-secondmate-home marker id (a
#                            routed task spawned inside a secondmate home)
#
# Wire shape: version 00 only, "00-<32 hex trace>-<16 hex span>-<2 hex flags>",
# with the trace id and span id never all-zero (W3C rejects both). New roots use
# RANDOM ids from /dev/urandom. The root's `01` (sampled) flag records a
# sampling DECISION that downstream parent-based samplers honor; it does not
# guarantee any collector stores a span, and firstmate emits no spans itself.
#
# Security / trust boundary. This feature adds exactly one OTEL_* variable,
# OTEL_RESOURCE_ATTRIBUTES - the fixed key list above, rendered only from the
# task meta and the spawning home's secondmate marker, percent-encoded so no
# shell metacharacter survives - and adds no tracestate, no arbitrary
# environment injection, and no configurable or arbitrary command execution.
# It DOES run the fixed local utilities `od` and
# `tr` (resolved from PATH) to read a few bytes of entropy - a small local
# pipeline with no configured provider, network, or watchdog, and no hard latency
# guarantee; any resolver failure that returns omits the carrier without aborting
# the spawn. Carrier-delivery failure also omits telemetry and continues when the
# backend clears its input; if the backend reports that partial input could not be
# cleared, fm-spawn refuses to append the launch command. Every carrier this lib
# yields is either a firstmate-MINTED random root that reads no prompt, path,
# task prose, credential, or arbitrary environment key, or the same task's
# previously recorded carrier reused verbatim from its own meta. Ambient
# TRACEPARENT is never read, so no caller-controlled bytes enter a new carrier.
#
# Root / recovery semantics (the trace boundary is each task):
#   recovery - a valid traceparent already recorded in the meta file is reused
#              verbatim, so a relaunched or recovered task keeps one stable
#              identity across restarts.
#   root     - any other spawn mints a fresh random trace id, fresh span id, and
#              sampled flags (01), beginning a new trace: one per task. The
#              spawning process's ambient TRACEPARENT is never adopted, so a
#              persistent supervisor's environment cannot chain its unrelated
#              routed tasks into one trace.

# Strict W3C traceparent validator: version 00, 32-hex trace id, 16-hex span id,
# 2-hex flags, with neither id all-zero. The regex lives in a variable because
# bash 3.2 only honors an unquoted right-hand side for =~.
fm_trace_context_valid() {  # <traceparent>
  local tp=$1
  local re='^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$'
  [[ $tp =~ $re ]] || return 1
  [ "${tp:3:32}" = "00000000000000000000000000000000" ] && return 1
  [ "${tp:36:16}" = "0000000000000000" ] && return 1
  return 0
}

# Echo <byte-count> random bytes as lowercase hex, or echo nothing and return 1
# on any entropy failure (unreadable source, short read, non-hex). -v stops od
# from collapsing repeated byte lines to '*'; the explicit length and charset
# checks turn a masked pipeline failure into a clean omission upstream.
fm_trace_context_hex() {  # <byte-count>
  local bytes=$1 hex
  hex=$(LC_ALL=C od -An -v -tx1 -N "$bytes" /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  case "$hex" in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#hex}" -eq "$((bytes * 2))" ] || return 1
  printf '%s' "$hex"
}

# True when the capability is enabled for this home. The env override wins so a
# spawn can be forced on or off without touching the file; otherwise the
# presence of config/trace-context decides, and its absence is the default-off.
fm_trace_context_enabled() {  # <config-dir>
  local config_dir=$1 v
  # A non-empty value is an explicit override; unset OR empty defers to the file
  # (the conventional "empty is like unset" behavior).
  if [ -n "${FM_TRACE_CONTEXT:-}" ]; then
    v=$(printf '%s' "$FM_TRACE_CONTEXT" | tr '[:upper:]' '[:lower:]')
    case "$v" in
      1 | on | true | yes) return 0 ;;
      *) return 1 ;;
    esac
  fi
  [ -f "$config_dir/trace-context" ]
}

# Echo the lock pid that owns the effective-state file's home, or fail when the
# adjacent session lock is absent or malformed. Binding the decision to this
# token makes a prior session's record inactive even if publication cannot
# replace or remove that stale file.
fm_trace_context_session_lock() {  # <effective-state-file>
  local effective_file=$1 state_dir lock_pid
  state_dir=${effective_file%/*}
  [ "$state_dir" = "$effective_file" ] && state_dir=.
  # Grouped so the stderr redirect is in place BEFORE the input redirect is
  # attempted: an absent lock is an ordinary silent "not locked" answer, and a
  # trailing 2>/dev/null on the bare read would still leak the open failure.
  { IFS= read -r lock_pid < "$state_dir/.lock"; } 2>/dev/null || return 1
  case "$lock_pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$lock_pid" -gt 1 ] || return 1
  printf '%s' "$lock_pid"
}

fm_trace_context_session_start() {  # <config-dir> <effective-state-file>
  local config_dir=$1 effective_file=$2 value=off lock_pid tmp
  lock_pid=$(fm_trace_context_session_lock "$effective_file") || {
    rm -f "$effective_file" 2>/dev/null || true
    return 0
  }
  fm_trace_context_enabled "$config_dir" && value=on
  tmp=$(mktemp "$effective_file.tmp.XXXXXX" 2>/dev/null) || {
    rm -f "$effective_file" 2>/dev/null || true
    return 0
  }
  if ! printf '%s %s\n' "$lock_pid" "$value" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$effective_file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    rm -f "$effective_file" 2>/dev/null || true
  fi
  return 0
}

fm_trace_context_session_effective() {  # <effective-state-file>
  local effective_file=$1 current_lock recorded_lock='' value='' extra=''
  current_lock=$(fm_trace_context_session_lock "$effective_file") || {
    printf '%s' off
    return 0
  }
  if [ -f "$effective_file" ] && [ ! -L "$effective_file" ]; then
    IFS=' ' read -r recorded_lock value extra < "$effective_file" 2>/dev/null || true
  fi
  if [ "$recorded_lock" = "$current_lock" ] && [ "$value" = on ] && [ -z "$extra" ]; then
    printf '%s' on
  else
    printf '%s' off
  fi
}

# Echo any traceparent already recorded in <meta-file>, else nothing. Used for
# the recovery path so a relaunch reuses the first spawn's identity.
fm_trace_context_recorded() {  # <meta-file>
  local meta=$1 line
  [ -f "$meta" ] || return 0
  line=$(grep '^traceparent=' "$meta" 2>/dev/null | head -n1) || return 0
  printf '%s' "${line#traceparent=}"
}

# Mint a fresh sampled root traceparent. Echo nothing and return 1 on entropy
# or validation failure so the caller can omit telemetry.
fm_trace_context_mint() {
  local trace span tp
  trace=$(fm_trace_context_hex 16) || return 1
  span=$(fm_trace_context_hex 8) || return 1
  tp="00-$trace-$span-01"
  fm_trace_context_valid "$tp" || return 1
  printf '%s' "$tp"
}

# Public entry point. Echo the single carrier to inject and record, or nothing.
# Always returns 0 so a spawn is never aborted by a telemetry decision. The
# recorded value wins so recovery keeps one task identity; otherwise a fresh
# root is minted, never derived from this process's environment.
fm_trace_context_resolve() {  # <config-dir> <meta-file>
  local config_dir=$1 meta=$2 existing
  fm_trace_context_enabled "$config_dir" || return 0
  existing=$(fm_trace_context_recorded "$meta")
  if fm_trace_context_valid "$existing"; then
    printf '%s' "$existing"
    return 0
  fi
  fm_trace_context_mint || return 0
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
# list owned by this file's header, in that order) rendered from <meta-file>,
# or nothing when the meta is absent or carries no task id. Always returns 0:
# an attribute decision is omitted safely and never aborts the spawn. Values
# derive only from the task meta and, for a routed task inside a secondmate
# home, the spawning home's .fm-secondmate-home marker - never from task
# prose, a prompt, or the ambient environment.
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
  if [ -z "$home_dir" ] && [ -n "$project" ]; then
    home_dir=${project%/*}
    [ "$home_dir" = "$project" ] && home_dir=''
  fi
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
