# shellcheck shell=bash
# Minimal OTLP/HTTP span emission for firstmate's own lifecycle events
# (default-off; the carrier seam itself is bin/fm-trace-context-lib.sh).
#
# docs/trace-context.md owns the rationale for first-party lifecycle emission.
# Emission is a library, not a daemon: one bounded curl per lifecycle
# event, run inside the script that already owns the event, with no collector,
# storage, UI, vendor coupling, retry, queue, or durable emission state. A
# receiver that is absent, down, slow, or refusing is indistinguishable from
# the capability being off: every failure is silent.
#
# Usage: . bin/fm-trace-span-lib.sh
#
# Public entry point:
#   fm_trace_span_emit <meta-file> <name> <start-ms|-> <end-ms|->
#       [--root] [--status ok|error|unset] [--link <traceparent>]
#       [key=value ...]
#
#   Emits one span named <name> for the task whose state/<id>.meta is
#   <meta-file>, and ALWAYS returns 0: telemetry is omitted safely and never
#   aborts the caller. It returns before any work when the meta records no
#   valid `traceparent=` carrier or when the home's frozen trace-context
#   session decision (fm_trace_context_session_effective) is off, so a
#   disabled home emits nothing and an enabled one cannot outlive its
#   session's decision.
#
#   <start-ms>/<end-ms> are epoch milliseconds; `-` means now
#   (fm_timing_now_ms). A non-numeric value is treated like `-`, and an end
#   before its start is clamped so a span never has negative duration.
#   Teardown passes `-` for a missing `trace_started=` mint time, so that root
#   starts at emission time; start and end are resolved separately.
#
#   --root uses the carrier's span id as this span's id and leaves it
#   parentless; without it a fresh random span id is minted
#   (fm_trace_context_hex 8) and the carrier's span id becomes the parent.
#   bin/fm-teardown.sh owns root emission at record removal. There is no
#   delivery receipt or deduplication if cleanup is interrupted and repeated.
#
#   --status ok maps to OTLP code 1 (OK), error to 2 (ERROR); anything else,
#   including the default, omits the status field (UNSET).
#
#   --link <traceparent> records one OTel span link referencing that W3C
#   traceparent's trace and span ids, only on a --root span and only when the
#   value passes strict W3C validation; a child span, an empty value, or an
#   invalid value silently omits the link, so only validated bytes can enter
#   the links array on the task root. A link never parents the span,
#   never changes the emitted trace id, and never adopts ambient context: the
#   only producer of link values is the task meta's `trace_link=` field,
#   resolved by fm_trace_context_link_resolve inside a marked secondmate home
#   (bin/fm-trace-context-lib.sh's header owns that boundary).
#
#   Each key=value argument becomes one string-valued span attribute.
#
# Wire shape (this header is the owner; the receivers are protocol-standard):
#   One OTLP/JSON `ExportTraceServiceRequest` per call: resource attributes
#   `service.name=firstmate` plus exactly the `firstmate.*` keys rendered by
#   fm_trace_span_resource_json: firstmate.task.id, firstmate.project (basename),
#   firstmate.home (parent of the metadata directory), firstmate.task.kind,
#   firstmate.harness, firstmate.model, firstmate.effort, firstmate.spawn_gen,
#   and firstmate.secondmate.id only for kind=secondmate (the task id).
#   Absent metadata values are omitted; one scope named firstmate;
#   span kind INTERNAL (1);
#   ids as lowercase hex strings; timestamps as decimal nanosecond strings;
#   all attribute values strings. A --link value on a --root span that passes
#   strict W3C validation adds exactly one `links` entry {"traceId","spanId"}
#   for that traceparent's ids; a child span or an invalid or absent link
#   omits the `links` field.
#   The span catalogue as implemented:
#     firstmate.spawn - bin/fm-spawn.sh, after the launch line is sent and the
#       backlog transition committed, so a refused spawn emits nothing;
#       attributes firstmate.relaunch, firstmate.spawn_gen,
#       firstmate.spawn_gen.prior (relaunch only), firstmate.backend,
#       firstmate.window.
#     firstmate.task (root) - bin/fm-teardown.sh, immediately before the
#       backlog record removal, with the terminal outcome read from the last
#       done/failed event recognized by status_line_verb before the status
#       file is retired (including tagged terminal events);
#       done maps to OK, failed to ERROR, and no such line leaves status UNSET
#       with outcome retired for a secondmate or unknown otherwise;
#       attributes firstmate.task.outcome (done, failed, retired, unknown),
#       firstmate.task.mode, firstmate.task.yolo, firstmate.pr.url,
#       firstmate.teardown.forced, firstmate.spawn_gen; a routed task's
#       recorded `trace_link=` rides the root as its span link (a primary
#       home records none).
#     firstmate.pr.ready - bin/fm-pr-check.sh, immediately after the validated
#       canonical PR identity is committed to the task meta and re-verified,
#       before the poll publish that only arms watching; a rejected request
#       exits before any emission. Attributes firstmate.pr.url,
#       firstmate.pr.head (present only when the forge supplied one).
#     firstmate.pr.merged - fm_merge_outcome_report in
#       bin/fm-merge-outcome-lib.sh, after the canonical outcome publication
#       and its dedup marker commit succeed, so a self-performed merge
#       (bin/fm-pr-merge.sh) and a poll-detected merge (bin/fm-watch.sh) share
#       one emission point and the already-recorded dedup return emits nothing
#       new; a failed publication emits nothing. Attributes firstmate.pr.url,
#       firstmate.merge.origin (self, poll), firstmate.merge.authority
#       (yolo, away-grant, attended, external; omitted when none is known).
#     firstmate.steer - bin/fm-send.sh, immediately after durable inbox
#       delivery (local enqueue or remote inbox leg), or after verified-only
#       typed submit and --key delivery, before later bookkeeping;
#       attributes firstmate.plane (inbox, typed, key), firstmate.inbox.seq
#       (local inbox sends only - a remote record's sequence lives in the
#       remote home), firstmate.corr (a marked secondmate request's
#       correlation id), firstmate.decision.key (each --resolve-key,
#       comma-joined), firstmate.fire_and_forget=true for an explicit
#       fire-and-forget delivery, firstmate.delivery.id for a remote
#       fire-and-forget delivery. Never the message content.
#     firstmate.promote - bin/fm-promote.sh after the promoted task record is
#       published; attributes firstmate.task.kind.prior (always scout -
#       promotion only runs on kind=scout), firstmate.task.mode,
#       firstmate.task.yolo.
#     firstmate.control - bin/fm-control.sh after a verified interrupt or
#       exit postcondition, at the verb dispatch site so a relaunch's
#       internal stop emits nothing (the replacement launch already emits
#       firstmate.spawn); attributes firstmate.control.verb (interrupt,
#       exit), firstmate.control.confirmed (interrupt: the adapter-owned
#       cancellation claim as true/false; exit: always true - the
#       recovery-grade classifier proved the stop or the agent was already
#       gone), firstmate.control.proof (interrupt: endpoint or agent-alive),
#       firstmate.control.result (exit: stopped or already-stopped).
#     firstmate.hold - bin/fm-captain-hold.sh, after a successful answer,
#       release, or verified reconcile close has been durably published,
#       never on a replay of an already-completed close; covers the
#       recorded hold-set time through that settlement on the held task's
#       trace, or the same-home origin task's trace for a separate --origin
#       call; attributes firstmate.hold.close_mode (answered, released,
#       repaired, reconciled) and firstmate.hold.reason (bounded),
#       read from the pre-close record because the close legitimately
#       removes them.
#     firstmate.reply - bin/fm-pending-reply-lib.sh, once per newly settled
#       pending-reply record in the parent home, after the durable resolved
#       fields are committed; covers the confirmed delivery through the
#       correlated settlement; attributes firstmate.corr,
#       firstmate.reply.via.
#     firstmate.wake - bin/fm-wake-drain.sh, per consumed queue row whose key
#       maps to a home task (fm_wake_status_key_map), after the
#       acknowledgement commit; covers the row's queue time through the one
#       acknowledgement instant shared by the batch, from the live meta or
#       the minimum context presentation captured for a task since torn
#       down; attributes firstmate.wake.kind, firstmate.wake.seq,
#       firstmate.wake.key. Only signal rows carry task status keys today,
#       so signal is the only kind that reaches emission; the emitter's kind
#       allowlist (signal, stale, check) and the key mapping are separate
#       bounded checks, and heartbeat is excluded by both.
#     firstmate.handoff - bin/fm-backlog-handoff.sh, one span per backlog key
#       after that key's move really lands: a local route right after the
#       atomic tasks-axi mv into the secondmate backlog succeeds, a remote
#       route right after the durable remote receipt confirms the delivered
#       outbox (so a merely staged, undelivered outbox emits nothing);
#       child of the secondmate agent's own carrier read from the parent
#       home's state/<id>.meta, emitted by the parent on both routes;
#       attributes firstmate.backlog.item (the moved key) and firstmate.route
#       (local, remote); the secondmate identity is the resource-scope
#       firstmate.secondmate.id that agent's meta already renders.
#   Taskless rows (heartbeats, per-poll checks, window-keyed stale rows)
#   emit nothing, and every entry above is silent for a task without a
#   recorded carrier.
#
# Endpoint precedence (the OpenTelemetry SDK's own): OTEL_EXPORTER_OTLP_TRACES_ENDPOINT,
# else ${OTEL_EXPORTER_OTLP_ENDPOINT%/}/v1/traces, else
# http://127.0.0.1:4318/v1/traces. These variables are read from the
# firstmate process's own environment at emission time; a home that runs a
# local collector needs no configuration, and one that does not pays a single
# refused loopback connection per lifecycle event.
#
# Delivery: one `curl -sS --max-time 1 -o /dev/null
# -H 'Content-Type: application/json' --data-binary @- <endpoint>`; stdin is
# the JSON body; the exit status is ignored. curl absent, connection refused,
# timeout, and non-2xx are all the same silent no-op. Emission runs inside
# firstmate's own process, so config/launch-env-allowlist is unaffected.
#
# Security / trust boundary. The body carries only fixed-shape ids, the span
# name and attributes the caller passes, and resource values JSON-escaped
# by fm_trace_span_resource_json from the task's own meta; no prompt, credential,
# or arbitrary environment value is read into it. Metadata-derived paths,
# names, and the PR URL are sent as recorded, without redaction. A --link
# value reaches the body only after strict W3C validation, as two fixed-shape
# hex ids. The network
# operation is curl, resolved from PATH, posting to the endpoint above; there is no
# configured provider command, no tracestate, and no parentage from ambient
# context (a span link references recorded, validated ids without changing
# parentage). Because every failure is silent and bounded at one second, a
# missing or hostile endpoint can slow one lifecycle event by at most its
# --max-time and can never alter the caller's outcome.

# Dependencies are pure function-definition libraries, so re-sourcing is
# idempotent and this lib works both beside its usual hosts (fm-spawn.sh
# already sources fm-trace-context-lib.sh) and standalone in tests.
# shellcheck source=bin/fm-trace-context-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timing-lib.sh"

fm_trace_span_json_escape() {  # <string>
  local s=$1 out='' i ch code
  for ((i = 0; i < ${#s}; i++)); do
    ch=${s:i:1}
    case $ch in
      "\\") out+=$ch$ch ;;
      '"') out+="\\$ch" ;;
      *)
        printf -v code '%d' "'$ch"
        if [ "$code" -lt 32 ]; then
          printf -v ch '\\u%04x' "$code"
        fi
        out+=$ch
        ;;
    esac
  done
  printf '%s' "$out"
}

# Private: echo a leading-comma OTLP JSON string-attribute pair for one
# key=value argument, or nothing for a malformed pair, so a caller appends
# attributes in one pass and drops the first comma at assembly.
fm_trace_span_attr_json() {  # <key=value>
  local pair=$1 k v
  case $pair in
    *=*) k=${pair%%=*} v=${pair#*=} ;;
    *) return 0 ;;
  esac
  [ -n "$k" ] || return 0
  printf ',{"key":"%s","value":{"stringValue":"%s"}}' \
    "$(fm_trace_span_json_escape "$k")" "$(fm_trace_span_json_escape "$v")"
}

fm_trace_span_resource_json() {  # <meta-file>
  local meta=$1 id kind v key out=''
  [ -f "$meta" ] || return 0
  id=$(sed -n 's/^endpoint_task_id=//p' "$meta" 2>/dev/null | head -n 1)
  [ -n "$id" ] || id=$(basename "$meta" .meta)
  out=$(fm_trace_span_attr_json "firstmate.task.id=$id")
  v=$(sed -n 's/^project=//p' "$meta" 2>/dev/null | head -n 1)
  if [ -n "$v" ]; then
    out+="$(fm_trace_span_attr_json "firstmate.project=${v##*/}")"
  fi
  out+="$(fm_trace_span_attr_json "firstmate.home=$(dirname "$(dirname "$meta")")")"
  kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | head -n 1)
  if [ -n "$kind" ]; then
    out+="$(fm_trace_span_attr_json "firstmate.task.kind=$kind")"
    if [ "$kind" = secondmate ]; then
      out+="$(fm_trace_span_attr_json "firstmate.secondmate.id=$id")"
    fi
  fi
  for key in harness model effort spawn_gen; do
    v=$(sed -n "s/^${key}=//p" "$meta" 2>/dev/null | head -n 1)
    [ -n "$v" ] || continue
    out+="$(fm_trace_span_attr_json "firstmate.${key}=$v")"
  done
  printf '%s\n' "$out"
}

fm_trace_span_emit() {  # <meta-file> <name> <start-ms|-> <end-ms|->
  #          [--root] [--status ok|error|unset] [--link <traceparent>]
  #          [key=value ...]
  local meta=$1 name=$2 start_ms=$3 end_ms=$4
  shift 4
  local root=0 status='unset' link_tp='' pair
  while [ "$#" -gt 0 ]; do
    case $1 in
      --root) root=1 ;;
      --status)
        [ "$#" -ge 2 ] || break
        status=$2
        shift
        ;;
      --link)
        [ "$#" -ge 2 ] || break
        link_tp=$2
        shift
        ;;
      --*) : ;;                 # unknown flags are ignored, never fatal
      *) break ;;               # attribute arguments begin
    esac
    shift
  done

  # Gate on the frozen session decision first, then the recorded carrier; a
  # disabled home and an untraced task are the same silent no-op.
  local state_dir=${meta%/*}
  [ "$state_dir" = "$meta" ] && state_dir=.
  [ "$(fm_trace_context_session_effective "$state_dir/.trace-context-effective")" = on ] || return 0
  local carrier
  carrier=$(fm_trace_context_recorded "$meta")
  fm_trace_context_valid "$carrier" || return 0

  local span_id parent_id=''
  if [ "$root" = 1 ]; then
    span_id=${carrier:36:16}
  else
    span_id=$(fm_trace_context_hex 8) || return 0
    parent_id=${carrier:36:16}
  fi

  case $start_ms in
    '' | *[!0-9]*) start_ms=$(fm_timing_now_ms) ;;
  esac
  case $end_ms in
    '' | *[!0-9]*) end_ms=$(fm_timing_now_ms) ;;
  esac
  [ "$end_ms" -ge "$start_ms" ] || end_ms=$start_ms

  local attrs_json='{"key":"service.name","value":{"stringValue":"firstmate"}}'
  attrs_json+="$(fm_trace_span_resource_json "$meta")"

  local span_attrs_json=''
  for pair in "$@"; do
    span_attrs_json+="$(fm_trace_span_attr_json "$pair")"
  done

  local tail_json=''
  case $status in
    ok) tail_json='"status":{"code":1}' ;;
    error) tail_json='"status":{"code":2}' ;;
  esac
  [ -z "$tail_json" ] || tail_json=",$tail_json"

  # One strictly validated span link on the task root, or none: only
  # fixed-shape hex ids from a conformant traceparent can reach the links array.
  local links_json=''
  if [ "$root" = 1 ] && fm_trace_context_valid "$link_tp"; then
    links_json=',"links":[{"traceId":"'"${link_tp:3:32}"'","spanId":"'"${link_tp:36:16}"'"}]'
  fi

  local span_json
  span_json='{"traceId":"'"${carrier:3:32}"'","spanId":"'"$span_id"'",'
  [ -z "$parent_id" ] || span_json+='"parentSpanId":"'"$parent_id"'",'
  span_json+='"name":"'$(fm_trace_span_json_escape "$name")'","kind":1,'
  span_json+='"startTimeUnixNano":"'"$((start_ms * 1000000))"'",'
  span_json+='"endTimeUnixNano":"'"$((end_ms * 1000000))"'",'
  span_json+='"attributes":['"${span_attrs_json#,}"']'"$tail_json$links_json"
  span_json+='}'

  command -v curl >/dev/null 2>&1 || return 0
  local endpoint=${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:-}
  if [ -z "$endpoint" ] && [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
    endpoint="${OTEL_EXPORTER_OTLP_ENDPOINT%/}/v1/traces"
  fi
  [ -n "$endpoint" ] || endpoint='http://127.0.0.1:4318/v1/traces'
  printf '%s' '{"resourceSpans":[{"resource":{"attributes":['"$attrs_json"']},"scopeSpans":[{"scope":{"name":"firstmate"},"spans":['"$span_json"']}]}]}' \
    | curl -sS --max-time 1 -o /dev/null -H 'Content-Type: application/json' --data-binary @- "$endpoint" >/dev/null 2>&1 || true
  return 0
}
