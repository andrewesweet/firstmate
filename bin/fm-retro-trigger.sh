#!/usr/bin/env bash
# fm-retro-trigger.sh - durable retrospective trigger: idempotent per-retro
# receipts from closure and anomaly producers, one filed backlog row per
# generation, and generational spend lanes.
#
# Opt-in. The feature is enabled only by the local, gitignored
# `config/retro-cadence` file under the effective home (FM_CONFIG_OVERRIDE
# selects the config directory outright; else FM_HOME/config). Absent config
# makes every command below a silent no-op (exit 0, no output, nothing
# written), so no producer changes behaviour and no store is created.
#
# Config keys, all optional, `key=value` one per line, `#` comments:
#   spend_usd=<positive number>          default 150
#   median_multiplier=<positive number>  default 2
#   done_unseen_minutes=<positive int>   default 30
# An unknown key or a malformed value is a loud refusal (exit 2, stderr names
# the key) rather than a silent default, so a fat-fingered threshold cannot
# masquerade as the intended one. done_unseen_minutes is read by the
# fm-wake-lib.sh presentation hook, which re-resolves the same file. The file
# is not inherited by secondmate homes; each home that wants the trigger
# writes its own.
#
# Store: `state/retro-trigger/` under the effective home (FM_STATE_OVERRIDE
# selects the state directory; else FM_HOME/state). This directory is private
# to this module; nothing else reads or writes it.
#   generation            one line, the current generation id (g<epoch>[-x])
#   receipts/<gen>/       one receipt file per observed fact, durable (each
#                         written to a temp file and renamed into place)
#                         before anything is published
#   open-row              one line, the open trigger backlog row id; present
#                         exactly while this generation's trigger row is open
#   archive/<retro-id>/   a completed generation's receipts, moved here by
#                         `reset`, with a `generation` file naming the id
#   .lock                 lock directory serializing observers and reset
#
# Commands:
#   observe closure <task-id> [--cost <usd>]
#       One receipt per closed task, idempotent per task id: a repeat observe
#       of the same task id in the same generation changes nothing, whatever
#       the cost arguments. With --cost the receipt lands in the known lane;
#       without it, the unknown lane. The unknown lane is the honest default:
#       today no producer carries a cost figure, and the flag exists so a
#       later cost source can feed the known lane without changing the store.
#   observe anomaly <kind> <task-id> <evidence>
#       kinds: needs-decision, blocked, ci-repair, done-unseen.
#       Idempotent per (kind, task-id, evidence). ci-repair has no mechanical
#       signal in firstmate today and exists so firstmate can record one by
#       hand. needs-decision and blocked are recorded by the
#       fm-wake-lib.sh presentation hook when it presents such a status
#       line; evidence is the line's [key=...] decision key, else the first
#       80 bytes. done-unseen is recorded only when the hook can bind the
#       presented done: line to a queued wake row epoch - when the drain's
#       unread span holds that one line and a direct signal row carries the
#       key; the bound epoch is that key's latest collapsed row epoch, which
#       is never earlier than the row that surfaced the line, so the wait is
#       under-estimated, never over-estimated - and only when presentation
#       time is at least done_unseen_minutes past that epoch; the evidence
#       then names the epoch ("epoch=<epoch> <line>") and this script, not
#       the hook, applies the threshold. A done: line with no bindable epoch
#       is never approximated: the producer stays silent.
#       The other kinds are wired by producers (fm-wake-lib.sh's
#       presentation hook; fm-teardown.sh's closure hook).
#   status
#       Current generation: known-lane spend, known and unknown closure
#       counts, the running median of known closure costs, anomaly count,
#       and the open trigger row if one is open.
#   reset <retro-id>
#       Close the generation: move its receipts under archive/<retro-id>/,
#       clear the open row, and start the next generation. Run by firstmate
#       when it routes the retrospective. Safe to re-run; a repeated
#       <retro-id> archives beside the first with a numeric suffix.
#
# Firing rule, evaluated once per NEW receipt while holding the lock and
# never while this generation's trigger row is open (an open row absorbs
# every later observe: the receipt is appended, nothing else is touched):
#   1. any anomaly receipt fires;
#   2. known-lane spend since the last reset reaching spend_usd fires;
#   3. a known closure whose cost exceeds median_multiplier times the running
#      median of all known closure costs of the generation, including the new
#      one, fires - and only when at least three known closures exist.
# A done-unseen observation under the threshold records nothing at all.
# The first matching rule wins and names its receipt. Firing files exactly
# one QUEUED backlog row in this home through bin/fm-tasks-axi.sh
# (kind scout, repo -, stable id retro-trigger-<generation>, body naming the
# receipt that fired and pointing at the store) and then enqueues exactly one
# `check:` wake through bin/fm-wake-lib.sh's durable wake queue so the next
# handling turn sees it. This script never dispatches the retrospective and
# never touches a secondmate home.
#
# Every command is safe to re-run. Every step's failure is reported on
# stderr and exits non-zero with the durable prefix intact: a receipt that
# landed but could not fire is retried by the next new receipt's observe,
# because no open-row marker exists until both the backlog row and its check
# wake have landed. The retry re-runs the whole firing step, so a failure
# after either publication dedupes rather than duplicates: tasks-axi add is
# idempotent for the stable row id, and the wake drain collapses repeated
# (check, row-id) rows into one presentation.
#
# Producers never fail the operation they ride on: bin/fm-teardown.sh and
# fm-wake-lib.sh's presentation hook call this script best-effort and keep
# their own success independent of any receipt or firing failure.

set -u

RT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$RT_SELF_DIR/.." && pwd)}"
RT_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-${FM_ROOT:-$RT_ROOT}}}"

usage() {
  awk '
    NR == 1 { next }
    /^# Opt-in\./ { exit }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

rt_fail() {
  printf 'fm-retro-trigger: %s\n' "$1" >&2
  exit "${2:-2}"
}

rt_config_path() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s/retro-cadence\n' "$FM_CONFIG_OVERRIDE"
  else
    printf '%s/config/retro-cadence\n' "$RT_HOME"
  fi
}

RT_CONFIG=
RT_SPEND_USD=150
RT_MEDIAN_MULTIPLIER=2
RT_DONE_UNSEEN_MINUTES=30

rt_valid_number() {  # positive decimal literal: digits with at most one dot
  case "$1" in
    ''|.*|*.) return 1 ;;
  esac
  case "$1" in
    *[!0-9.]*|*.*.*) return 1 ;;
  esac
  return 0
}

# Load config into RT_* globals. Absent file: silent inert no-op (exit 0).
# Present but malformed: loud refusal.
rt_require_config() {
  RT_CONFIG=$(rt_config_path)
  if [ -L "$RT_CONFIG" ]; then
    rt_fail "config must be a regular file, not a symlink: $RT_CONFIG"
  fi
  [ -f "$RT_CONFIG" ] || exit 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || rt_fail "$RT_CONFIG: not a key=value line: $line"
    case "$key" in
      spend_usd|median_multiplier|done_unseen_minutes) ;;
      *) rt_fail "$RT_CONFIG: unknown key: $key" ;;
    esac
    case "$value" in
      *[!0-9.]*) rt_fail "$RT_CONFIG: malformed value for $key: $value" ;;
    esac
    case "$key" in
      spend_usd)
        rt_valid_number "$value" \
          || rt_fail "$RT_CONFIG: spend_usd must be a positive number: $value"
        RT_SPEND_USD=$value
        ;;
      median_multiplier)
        rt_valid_number "$value" \
          || rt_fail "$RT_CONFIG: median_multiplier must be a positive number: $value"
        RT_MEDIAN_MULTIPLIER=$value
        ;;
      done_unseen_minutes)
        case "$value" in
          ''|*.*|0*) rt_fail "$RT_CONFIG: done_unseen_minutes must be a positive whole number: $value" ;;
        esac
        [ "$value" -gt 0 ] 2>/dev/null \
          || rt_fail "$RT_CONFIG: done_unseen_minutes must be a positive whole number: $value"
        RT_DONE_UNSEEN_MINUTES=$value
        ;;
    esac
  done < "$RT_CONFIG"
  awk -v spend="$RT_SPEND_USD" -v mult="$RT_MEDIAN_MULTIPLIER" \
    'BEGIN { exit !((spend + 0) > 0 && (mult + 0) > 0) }' \
    || rt_fail "$RT_CONFIG: spend_usd and median_multiplier must be positive numbers"
}

RT_STATE=${FM_STATE_OVERRIDE:-${STATE:-$RT_HOME/state}}
RT_DIR="$RT_STATE/retro-trigger"
RT_GENERATION_FILE="$RT_DIR/generation"
RT_RECEIPTS="$RT_DIR/receipts"
RT_ARCHIVE="$RT_DIR/archive"
RT_OPEN_ROW="$RT_DIR/open-row"
RT_LOCK="$RT_DIR/.lock"

rt_valid_slug() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

rt_atomic_write() {  # <path> <content>
  local target=$1 content=$2 tmp
  tmp=$(mktemp "$RT_DIR/.write.XXXXXX") || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$target"
}

rt_current_generation() {
  cat "$RT_GENERATION_FILE" 2>/dev/null
}

# Ensure a generation exists; print it. Caller holds the lock (except status).
rt_ensure_generation() {
  local gen
  gen=$(rt_current_generation)
  if [ -n "$gen" ]; then
    [ -d "$RT_RECEIPTS/$gen" ] || mkdir -p "$RT_RECEIPTS/$gen" || return 1
    printf '%s\n' "$gen"
    return 0
  fi
  gen="g$(date +%s)"
  while [ -e "$RT_RECEIPTS/$gen" ] || [ -L "$RT_RECEIPTS/$gen" ]; do
    gen="${gen}-x"
  done
  mkdir -p "$RT_RECEIPTS/$gen" || return 1
  rt_atomic_write "$RT_GENERATION_FILE" "$gen" || return 1
  printf '%s\n' "$gen"
}

rt_open_row() {
  cat "$RT_OPEN_ROW" 2>/dev/null
}

# One "<lane> <cost>" line per closure receipt of a generation. The literal
# glob is safe: with no receipts the loop breaks on the first [ -f ] check.
rt_closure_lanes() {  # <gen>
  local f lane cost
  for f in "$RT_RECEIPTS/$1"/closure-*.receipt; do
    [ -f "$f" ] || return 0
    lane=$(sed -n 's/^lane=//p' "$f" | head -1)
    cost=$(sed -n 's/^cost=//p' "$f" | head -1)
    printf '%s %s\n' "${lane:--}" "${cost:--}"
  done
}

rt_known_costs() {  # <gen>
  rt_closure_lanes "$1" | awk '$1 == "known" { print $2 }'
}

rt_count_receipts() {  # <gen> <receipt-filename-prefix>
  local f count=0
  for f in "$RT_RECEIPTS/$1"/"$2"*.receipt; do
    [ -f "$f" ] || break
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

rt_receipt_idempotent() {  # <gen> <receipt-filename>
  [ -e "$RT_RECEIPTS/$1/$2" ] || [ -L "$RT_RECEIPTS/$1/$2" ]
}

rt_write_receipt() {  # <gen> <receipt-filename> <kind> <task> <lane> <cost> <evidence>
  local dir="$RT_RECEIPTS/$1" name=$2 kind=$3 task=$4 lane=$5 cost=$6 evidence=$7 tmp
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.receipt.XXXXXX") || return 1
  {
    printf 'kind=%s\n' "$kind"
    printf 'task=%s\n' "$task"
    printf 'lane=%s\n' "$lane"
    printf 'cost=%s\n' "$cost"
    printf 'evidence=%s\n' "$evidence"
    printf 'epoch=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$dir/$name"
}

rt_receipt_summary() {  # <kind> <task>  -> human clause naming the receipt
  case "$1" in
    closure) printf 'closure receipt for task %s' "$2" ;;
    *) printf '%s anomaly receipt for task %s' "$1" "$2" ;;
  esac
}

rt_median() {  # (known costs on stdin) -> running median, two decimals
  LC_ALL=C sort -n | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) { printf "-" }
      else if (NR % 2 == 1) { printf "%.2f", v[(NR + 1) / 2] }
      else { printf "%.2f", (v[NR / 2] + v[NR / 2 + 1]) / 2 }
    }'
}

# Evaluate the firing rules for a just-written receipt; fire at most once per
# generation. Caller holds the lock. Returns non-zero on a filing failure
# with the reason already on stderr.
rt_evaluate_firing() {  # <gen> <kind> <task> <cost> <lane>
  local gen=$1 kind=$2 task=$3 cost=$4 lane=$5 fire_reason='' spend median
  [ -f "$RT_OPEN_ROW" ] && return 0

  if [ "$kind" != closure ]; then
    fire_reason="anomaly ${kind} recorded"
  else
    spend=$(rt_known_costs "$gen" | awk '{ s += $1 } END { printf "%.2f", s + 0 }')
    if awk -v spend="$spend" -v threshold="$RT_SPEND_USD" \
      'BEGIN { exit !(spend >= threshold) }'; then
      fire_reason="known-lane spend ${spend} USD reached spend_usd ${RT_SPEND_USD}"
    elif [ "$lane" = known ]; then
      if [ "$(rt_known_costs "$gen" | wc -l)" -ge 3 ]; then
        median=$(rt_known_costs "$gen" | rt_median)
        if awk -v cost="$cost" -v median="$median" -v mult="$RT_MEDIAN_MULTIPLIER" \
          'BEGIN { exit !(cost > median * mult) }'; then
          fire_reason="closure cost ${cost} USD exceeds ${RT_MEDIAN_MULTIPLIER}x the running median ${median}"
        fi
      fi
    fi
  fi
  [ -n "$fire_reason" ] || return 0

  rt_fire "$gen" "$fire_reason" "$(rt_receipt_summary "$kind" "$task")"
}

rt_fire() {  # <gen> <fire-reason> <receipt-summary>
  local gen=$1 fire_reason=$2 receipt=$3 row_id body
  row_id="retro-trigger-$gen"
  body="Durable retrospective trigger fired in generation $gen: $fire_reason. Receipt: $receipt. Receipts: $RT_DIR/receipts/$gen/ (bin/fm-retro-trigger.sh status). One open row absorbs later anomalies; run bin/fm-retro-trigger.sh reset <retro-id> when routing this retrospective."
  "$RT_SELF_DIR/fm-tasks-axi.sh" add "$row_id" \
    "Run the retrospective due for trigger generation $gen" \
    --kind scout --repo - --body "$body" >/dev/null || {
      printf 'fm-retro-trigger: could not file trigger row %s\n' "$row_id" >&2
      return 1
    }
  if ! rt_enqueue_wake "$gen" "$row_id"; then
    printf 'fm-retro-trigger: filed %s but could not enqueue its check wake\n' "$row_id" >&2
    return 1
  fi
  rt_atomic_write "$RT_OPEN_ROW" "$row_id" || {
    printf 'fm-retro-trigger: filed and surfaced %s but could not record the open-row marker\n' "$row_id" >&2
    return 1
  }
  printf 'fm-retro-trigger: filed trigger row %s (%s)\n' "$row_id" "$fire_reason" >&2
  return 0
}

rt_enqueue_wake() {  # <gen> <row-id>
  rt_load_wake_lib || return 1
  fm_wake_append check "$2" \
    "check: retro trigger $1 fired; queued backlog row $2 holds the next retrospective"
}

rt_load_wake_lib() {
  [ -n "${RT_WAKE_LIB_LOADED:-}" ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$RT_SELF_DIR/fm-wake-lib.sh" || return 1
  RT_WAKE_LIB_LOADED=1
}

rt_observe_closure() {  # <task-id> [--cost <usd>]
  local task=$1 cost='' lane=unknown
  shift
  if [ "${1:-}" = --cost ]; then
    shift
    [ -n "${1:-}" ] || rt_fail "observe closure --cost requires a value"
    rt_valid_number "$1" || rt_fail "malformed --cost value: $1"
    cost=$1
    lane=known
    shift
  fi
  [ $# -eq 0 ] || rt_fail "unexpected argument to observe closure: $1"

  rt_lock_or_fail
  local gen name
  gen=$(rt_ensure_generation) || { rt_lock_release; rt_fail "cannot prepare generation" 1; }
  name="closure-$task.receipt"
  if rt_receipt_idempotent "$gen" "$name"; then
    rt_lock_release
    return 0
  fi
  rt_write_receipt "$gen" "$name" closure "$task" "$lane" "${cost:--}" - \
    || { rt_lock_release; printf 'fm-retro-trigger: could not write the receipt for %s\n' "$task" >&2; exit 1; }
  if ! rt_evaluate_firing "$gen" closure "$task" "$cost" "$lane"; then
    rt_lock_release
    exit 1
  fi
  rt_lock_release
  return 0
}

rt_observe_anomaly() {  # <kind> <task-id> <evidence> (kind validated by main)
  local kind=$1 task=$2 evidence=$3 name hash epoch now
  case "$evidence" in
    ''|*[$'\t\r\n']*) rt_fail "evidence must be one non-empty line without control characters" ;;
  esac
  if [ "$kind" = done-unseen ]; then
    # The evidence names the bound wake-queue row epoch; this script owns the
    # threshold, so an observation under done_unseen_minutes records nothing.
    case "$evidence" in
      epoch=[0-9]*\ *) ;;
      *) rt_fail "done-unseen evidence must name its bound wake row epoch: epoch=<epoch> <line>" ;;
    esac
    epoch=${evidence#epoch=}
    epoch=${epoch%% *}
    now=$(date +%s)
    [ "$((now - epoch))" -ge "$((RT_DONE_UNSEEN_MINUTES * 60))" ] || return 0
  fi
  hash=$(printf '%s\n' "$kind" "$task" "$evidence" | sha256sum | LC_ALL=C cut -c1-8) \
    || rt_fail "cannot hash the evidence" 1
  name="anomaly-$kind-$hash.receipt"

  rt_lock_or_fail
  local gen
  gen=$(rt_ensure_generation) || { rt_lock_release; rt_fail "cannot prepare generation" 1; }
  if rt_receipt_idempotent "$gen" "$name"; then
    rt_lock_release
    return 0
  fi
  rt_write_receipt "$gen" "$name" "$kind" "$task" - - "$evidence" \
    || { rt_lock_release; printf 'fm-retro-trigger: could not write the receipt for %s\n' "$task" >&2; exit 1; }
  if ! rt_evaluate_firing "$gen" "$kind" "$task" - -; then
    rt_lock_release
    exit 1
  fi
  rt_lock_release
  return 0
}

rt_status() {
  local gen open spend known unknown anomalies median
  gen=$(rt_current_generation)
  if [ -z "$gen" ] || [ ! -d "$RT_RECEIPTS/$gen" ]; then
    printf 'generation: -\nknown_spend: -\nknown_closures: 0\nunknown_closures: 0\nmedian_known_cost: -\nanomalies: 0\nopen_row: -\n'
    return 0
  fi
  open=$(rt_open_row)
  [ -n "$open" ] || open=-
  known=$(rt_closure_lanes "$gen" | awk '$1 == "known" { n++ } END { printf "%d", n + 0 }')
  unknown=$(rt_closure_lanes "$gen" | awk '$1 == "unknown" { n++ } END { printf "%d", n + 0 }')
  spend=$(rt_known_costs "$gen" | awk '{ s += $1 } END { printf "%.2f", s + 0 }')
  anomalies=$(rt_count_receipts "$gen" anomaly-)
  if [ "$known" -gt 0 ]; then
    median=$(rt_known_costs "$gen" | rt_median)
  else
    median=-
  fi
  printf 'generation: %s\nknown_spend: %s\nknown_closures: %s\nunknown_closures: %s\nmedian_known_cost: %s\nanomalies: %s\nopen_row: %s\n' \
    "$gen" "$spend" "$known" "$unknown" "$median" "$anomalies" "$open"
}

rt_reset() {  # <retro-id>
  local retro_id=$1 gen dest='' newgen n=1
  rt_lock_or_fail
  gen=$(rt_current_generation)
  if [ -n "$gen" ] && [ -d "$RT_RECEIPTS/$gen" ]; then
    dest="$RT_ARCHIVE/$retro_id"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      while [ -e "$RT_ARCHIVE/$retro_id-$n" ] || [ -L "$RT_ARCHIVE/$retro_id-$n" ]; do
        n=$((n + 1))
      done
      dest="$RT_ARCHIVE/$retro_id-$n"
    fi
    mkdir -p "$RT_ARCHIVE" || { rt_lock_release; rt_fail "cannot create $RT_ARCHIVE" 1; }
    mv "$RT_RECEIPTS/$gen" "$dest" || { rt_lock_release; rt_fail "cannot archive generation $gen" 1; }
    rt_atomic_write "$dest/generation" "$gen" \
      || printf 'fm-retro-trigger: archived %s under %s without a generation marker\n' "$gen" "$dest" >&2
  fi
  rm -f "$RT_OPEN_ROW"
  # Start the next generation; a same-second reset cannot reuse the id.
  newgen="g$(date +%s)"
  while [ -e "$RT_RECEIPTS/$newgen" ] || [ -L "$RT_RECEIPTS/$newgen" ] \
    || [ "$newgen" = "$gen" ]; do
    newgen="${newgen}-x"
  done
  mkdir -p "$RT_RECEIPTS/$newgen" \
    || { rt_lock_release; rt_fail "cannot start generation $newgen" 1; }
  rt_atomic_write "$RT_GENERATION_FILE" "$newgen" \
    || { rt_lock_release; rt_fail "cannot record generation $newgen" 1; }
  rt_lock_release
  if [ -n "$dest" ]; then
    printf 'fm-retro-trigger: generation %s archived under %s; next generation %s\n' \
      "$gen" "$dest" "$newgen" >&2
  else
    printf 'fm-retro-trigger: no receipts to archive; next generation %s\n' "$newgen" >&2
  fi
  return 0
}

rt_lock_or_fail() {
  mkdir -p "$RT_DIR" || rt_fail "cannot create $RT_DIR" 1
  rt_load_wake_lib || rt_fail "cannot load the lock helpers" 1
  fm_lock_acquire_wait "$RT_LOCK" || rt_fail "cannot acquire the retro-trigger lock" 1
}

rt_lock_release() {
  if [ -n "${RT_WAKE_LIB_LOADED:-}" ]; then
    fm_lock_release "$RT_LOCK" || :
  fi
  return 0
}

main() {
  if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
    usage
    return 0
  fi
  case "${1:-}" in
    observe|status|reset) ;;
    '') usage >&2; return 2 ;;
    *) rt_fail "unknown command: $1 (expected observe, status, or reset)" ;;
  esac
  rt_require_config
  case "${1:-}" in
    status)
      [ $# -eq 1 ] || rt_fail "unexpected argument to status: $2"
      rt_status
      ;;
    reset)
      shift
      [ $# -eq 1 ] || { usage >&2; return 2; }
      rt_valid_slug "$1" || rt_fail "invalid retro id: $1"
      rt_reset "$1"
      ;;
    observe)
      shift
      case "${1:-}" in
        closure)
          shift
          [ -n "${1:-}" ] || { usage >&2; return 2; }
          rt_valid_slug "$1" || rt_fail "invalid task id: $1"
          rt_observe_closure "$@"
          ;;
        anomaly)
          shift
          [ $# -eq 3 ] || { usage >&2; return 2; }
          case "$1" in
            needs-decision|blocked|ci-repair|done-unseen) ;;
            *) rt_fail "unknown anomaly kind: $1 (expected needs-decision, blocked, ci-repair, or done-unseen)" ;;
          esac
          rt_valid_slug "$2" || rt_fail "invalid task id: $2"
          rt_observe_anomaly "$1" "$2" "$3"
          ;;
        *) rt_fail "unknown observe kind: ${1:-} (expected closure or anomaly)" ;;
      esac
      ;;
  esac
}

main "$@"
