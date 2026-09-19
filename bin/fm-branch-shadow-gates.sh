#!/usr/bin/env bash
# fm-branch-shadow-gates.sh - retrospective score of the six candidate gates
# over the Claude Code supervision-branch mod's shadow advisory records
# (docs/claude-supervision-branch.md, "Shadow advisory trial").
#
# Sibling, not extension: bin/fm-branch-shadow-score.sh owns the per-question
# agreement tables for the trial; this scorer owns the candidate gates. One
# record set, two different questions - which questions have durable labels,
# versus which absorb/suppress/arm/alert/order gates would have matched main's
# own later behavior - so two readable scripts beat one overloaded one.
#
# Records: only the full variant, repeat 1, scores. Every record since the
# trial's facts release carries a facts object (branch.ts) holding the per-task
# new status byte counts, pane identity and the watcher's stale escalation
# series, the structured pane observation, authoritative PR presence and
# identity, the severity class labels, the candidate Nouls from the record's
# own answers, and the wakeKey the outcome rows carry. A record without the
# facts, or without the inputs one gate needs, is counted unscorable for that
# gate, listed under -v, and never guessed.
#
# Ground truth per wake, joined by wakeKey:
#   - the branch outcome rows: any captain verdict labels the wake main; all-
#     routine rows label it routine; no rows leave it unmatched and out of
#     every tally;
#   - a later outcome-backstop surfacing (a routine row whose covered status
#     span, from the task's previous outcome row's endpoint, holds a captain-
#     relevant, non-keyed status line - the same line set fm-wake-drain.sh's
#     STATUS OUTCOME BACKSTOP prints) marks a routine label as a wrong absorb;
#     a task's first row has no previous endpoint and no durable receipt, so
#     its span is never scanned rather than guessed from byte 0;
#   - main's own later recorded action where the durable stores derive it: a
#     PR URL inside the wake's joined outcome summaries, a merge poll armed
#     for one of the wake's tasks (state/<task>.pr-poll or pr= in the meta,
#     read at scoring time so this signal is task-scoped, not wake-scoped),
#     and, for stale wakes, a worker incarnation newer than the wake (the
#     busy-state gen) as the stale repair; teardown is not a repair, since
#     every task is torn down once it finishes.
#
# The gates, fired on a full record's facts and answers at a floor F:
#   absorb-no-new-outcome   no_new_outcome Noul >= F and zero new status bytes
#   absorb-routine-working  route routine >= F and phase working|no_change >= F
#   stale-active-suppress   stale wake, stale_state active >= F, pane
#                           observation progressing -> the same pane's later
#                           stale wakes inside a bounded window (1800s) would
#                           be suppressed and the wedge series reset; scored on
#                           whether those later stale wakes were correctly
#                           absorbed (a firing wake whose own outcome was
#                           actionable is a delay-class wrong fire)
#   pr-ready-arm            phase finished_ready >= F and an authoritative PR
#                           present -> arm the merge poll and report ready
#                           from the durable PR source, never from the model
#   severity-alert          severity Score >= F in the security, privacy,
#                           data-loss, credential, or publication class ->
#                           immediate alert ahead of any summary
#   candidate-order         per-candidate Noul >= F ranks which candidate is
#                           reported first; scored against the order the branch
#                           actually chose (the lowest-seq joined outcome row);
#                           a captain-verdict candidate below the floor, or an
#                           absorb-all decision over one, is a loss-class
#                           wrong decision
# The state-read question is deliberately not scored: the six gates above are
# the trial's candidates, and the pre-existing classifier question is out of
# scope.
#
# Per gate the table prints eligible wakes, unscorable, fired, correct fires,
# wrong fires split into delay-only and loss class (loss = a captain-facing or
# actionable wake the gate would have swallowed), and missed = the branch
# absorbed the wake, the gate did not fire, and firing would have been
# warranted (the wake was absorbable for the absorb and stale gates; the
# absorbed wake carried PR-ready or actionable evidence for the arm and alert
# gates; not applicable to candidate-order). The floor sweep runs F over
# 0.70-0.99 in 0.01 steps and reports the lowest floor with zero loss-class
# wrong fires and the fire rate there. Overlapping stale-suppression chains
# are scored per firing wake; -v prints the raw detail for manual adjudication.
#
# Usage:
#   bin/fm-branch-shadow-gates.sh [-v] [<shadow-log>] [<outcomes-file>]
#
# The logs default to $STATE/branch-mod-shadow.jsonl and
# $STATE/branch-outcomes.jsonl; each wake's task records are read from $STATE.
# Exit 0 always; the tables are the result, and an absent shadow log prints
# only the empty tables.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
_fm_wake_require_classify

VERBOSE=0
args=()
for arg in "$@"; do
  case "$arg" in
    -v) VERBOSE=1 ;;
    -h | --help) sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$arg") ;;
  esac
done
LOG=${args[0]:-$STATE/branch-mod-shadow.jsonl}
OUTCOMES=${args[1]:-$STATE/branch-outcomes.jsonl}
command -v jq >/dev/null 2>&1 || { echo "fm-branch-shadow-gates: jq is required" >&2; exit 2; }

STALE_SUPPRESS_WINDOW=1800

if [ ! -f "$LOG" ]; then
  printf '### candidate gates over full-variant shadow records\n| gate | eligible | unscorable | fired | correct | wrong (delay-only) | wrong (loss) | missed (absorbed, gate silent) |\n|---|---|---|---|---|---|---|---|\n'
  printf '\n### floor sweep 0.70-0.99: lowest floor with zero loss-class wrong fires\n| gate | lowest clean floor | fires there | fire rate there |\n|---|---|---|---|\n'
  exit 0
fi

# One TSV line per full-variant, repeat-1 record. "-" marks an absent field so
# `read` never collapses consecutive empty tab fields; the raw read skips torn
# or malformed lines so one bad record can never drop the rest.
REC_ROWS=$(jq -R -r '
  fromjson? | select(type == "object") | . as $r |
  select($r.kind == "shadow" and $r.variant == "full" and (($r.repeat // 1) | tostring) == "1") |
  (($r.policy // {}) | (.choice_confidence_floor // 0.85)) as $cf |
  (($r.policy // {}) | (.noul_pass_above // 0.85)) as $npa |
  ($r.facts // null) as $f |
  ($r.answers // {}) as $ans |
  ($ans.severity.score // null) as $sv |
  ($f.severity_classes // null) as $sevc |
  (($sv | type) == "number" and ($sv >= 0) and ($sevc | type) == "array" and ($sv < ($sevc | length))) as $inrange |
  (if $inrange then ($sevc[$sv] | tostring) else "-" end) as $cls |
  [ ($r.wakeKey // "" | if . == "" then "-" else . end),
    (if ($r.wake // "" | test("(^|\n)stale:")) then "stale" else "plain" end),
    (($r.t // "" | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) // "-" | tostring),
    ($cf | tostring),
    ($npa | tostring),
    (if $r.unavailable != null then "unavailable" else "ok" end),
    (if $f == null then "nofacts" else "facts" end),
    (($ans.no_new_outcome.noul // null) as $n | (if ($n | type) == "number" then $n else null end) // "-" | tostring),
    ($ans.route.choice // "-" | tostring),
    (($ans.route.confidence // null) as $n | (if ($n | type) == "number" then $n else null end) // "-" | tostring),
    ($ans.phase.choice // "-" | tostring),
    (($ans.phase.confidence // null) as $n | (if ($n | type) == "number" then $n else null end) // "-" | tostring),
    ($ans.stale_state.choice // "-" | tostring),
    (($ans.stale_state.confidence // null) as $n | (if ($n | type) == "number" then $n else null end) // "-" | tostring),
    $cls,
    (if ($cls | test("security|privacy|data-loss|credential|publication"; "i")) then "hit" else "-" end),
    (if ($sevc | type) == "array" and ([(($sevc // [])[]) | tostring | test("security|privacy|data-loss|credential|publication"; "i")] | any) then "any" else "-" end),
    (($ans.severity.confidence // null) as $n | (if ($n | type) == "number" then $n else null end) // "-" | tostring),
    (if ($f.new_status_bytes | type) == "object" then ([($f.new_status_bytes // {})[] | numbers] | add // 0 | tostring) else "-" end),
    (if ($f.authoritative_pr | type) == "object" then (($f.authoritative_pr.present == true) | tostring) else "-" end),
    (($f.authoritative_pr.pr // null) // "-" | tostring),
    (($f.pane_observation.progressing // null) as $p | (if ($p | type) == "boolean" then $p else null end) // "-" | tostring),
    (($f.pane // null) // "-" | tostring),
    (($r.tasks // null) as $tsk | (if ($tsk | type) == "array" then ($tsk | length) else null end) // "-" | tostring),
    (if ($f.candidates | type) == "object" and ($f.candidates | length) > 0 then
      ($f.candidates | to_entries | sort_by(-(.value | if type == "number" then . else -1 end)) | map(.key + ":" + ((.value // "-") | tostring)) | join(",")) else "-" end)
  ] | @tsv' "$LOG" 2>/dev/null || true)

# One TSV line per branch outcome row.
OUT_ROWS=''
if [ -f "$OUTCOMES" ]; then
  OUT_ROWS=$(jq -R -r 'fromjson? | select(type == "object") |
    [ (.wakeKey // "" | if . == "" then "-" else . end),
      (.task // "" | if . == "" then "-" else . end),
      ((.seq // 0) | tostring),
      (.verdict // "-" | tostring),
      ((.statusEndpoint // 0) | tostring),
      (if ((.summary // "") | test("https://[^[:space:]]*/pull/[0-9]+")) then "pr" else "-" end) ] | @tsv' "$OUTCOMES" 2>/dev/null || true)
fi

declare -A WK_SEEN=() WK_CAPTAIN=() WK_BACKSTOP=() WK_PRROWS=() WK_FIRST=() WKFIRSTSEQ=() WK_CAPTASKS=() WK_TASKS=() WKMAX=() GMAX=() LAST_EP=()
declare -A WK_ISSTALE=() WKEPOCH=()

# Backstop span scan: does the task's status log hold, inside (from, endpoint],
# a captain-relevant line without a parseable decision key - the same line set
# fm-wake-drain.sh's STATUS OUTCOME BACKSTOP surfaces? Byte-exact line ends,
# mirroring backstop_routine_covered_lines in bin/fm-classify-lib.sh.
backstop_span_has_surface() {  # <task> <from> <endpoint>
  local task=$1 from=$2 endpoint=$3 f="$STATE/$1.status" line
  case "$task" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$f" ] || return 1
  case "$from:$endpoint" in *[!0-9:]*) return 1 ;; esac
  [ "$endpoint" -gt "$from" ] || return 1
  while IFS=$'\t' read -r _ line; do
    [ -n "$line" ] || continue
    status_is_captain_relevant "$line" || continue
    case "$(status_line_verb "$line")" in
      needs-decision | blocked) _fm_decision_key "$line" >/dev/null 2>&1 && continue ;;
    esac
    return 0
  done < <(LC_ALL=C perl -e '
    my ($path, $from, $endpoint) = @ARGV;
    open my $f, "<", $path or exit 1;
    binmode $f;
    while (defined(my $line = <$f>)) {
      my $end = tell($f);
      last if $end > $endpoint;
      next if $end <= $from;
      next unless $line =~ /[^\s]/;
      $line =~ s/[\r\n]+\z//;
      print "$end\t$line\n";
    }
  ' "$f" "$from" "$endpoint")
  return 1
}

while IFS=$'\t' read -r wake task seq verdict endpoint haspr; do
  { [ -n "$task" ] && [ "$task" != "-" ]; } || continue
  prev_ep=${LAST_EP[$task]:-0}
  LAST_EP[$task]=$endpoint
  { [ -n "$wake" ] && [ "$wake" != "-" ]; } || continue
  WK_SEEN[$wake]=1
  WK_TASKS[$wake]="${WK_TASKS[$wake]:-} $task"
  if [ "$verdict" = captain ]; then
    WK_CAPTAIN[$wake]=1
    WK_CAPTASKS[$wake]="${WK_CAPTASKS[$wake]:-} $task"
  fi
  if [ "$verdict" = routine ] && [ "$prev_ep" -gt 0 ] && [ -z "${WK_BACKSTOP[$wake]:-}" ]; then
    backstop_span_has_surface "$task" "$prev_ep" "$endpoint" && WK_BACKSTOP[$wake]=1
  fi
  [ "$haspr" = pr ] && WK_PRROWS[$wake]=1
  if [ -z "${WK_FIRST[$wake]:-}" ] || [ "$seq" -lt "${WKFIRSTSEQ[$wake]}" ]; then
    WK_FIRST[$wake]=$task
    WKFIRSTSEQ[$wake]=$seq
  fi
  wk_task_key="$wake|$task"
  [ "${WKMAX[$wk_task_key]:-0}" -lt "$seq" ] && WKMAX[$wk_task_key]=$seq
  [ "${GMAX[$task]:-0}" -lt "$seq" ] && GMAX[$task]=$seq
done <<< "$OUT_ROWS"

# Records into parallel arrays; "-" keeps meaning absent.
declare -a R_WK=() R_STALE=() R_EPOCH=() R_CF=() R_NPA=() R_AVAIL=() R_FACTS=() R_NOUL=() R_ROUTE=() R_ROUTECONF=() R_PHASE=() R_PHASECONF=() R_STALEC=() R_STALECONF=() R_SEVCLS=() R_SEVHIT=() R_SEVANY=() R_SEVCONF=() R_BYTES=() R_PRPRESENT=() R_PRID=() R_PROG=() R_PANE=() R_NTASKS=() R_CANDS=()
while IFS=$'\t' read -r wk st epoch cf npa avail facts noul route rconf phase pconf stalec sconf sevcls sevhit sevany sevconf bytes prpresent prid prog pane ntasks cands; do
  [ -n "$wk" ] || continue
  if [ "$st" = stale ]; then WK_ISSTALE[$wk]=1; fi
  if [ "$epoch" != "-" ]; then
    if [ -z "${WKEPOCH[$wk]:-}" ] || [ "$epoch" -lt "${WKEPOCH[$wk]}" ]; then WKEPOCH[$wk]=$epoch; fi
  fi
  R_WK+=("$wk"); R_STALE+=("$st"); R_EPOCH+=("$epoch"); R_CF+=("$cf"); R_NPA+=("$npa")
  R_AVAIL+=("$avail"); R_FACTS+=("$facts"); R_NOUL+=("$noul"); R_ROUTE+=("$route"); R_ROUTECONF+=("$rconf")
  R_PHASE+=("$phase"); R_PHASECONF+=("$pconf"); R_STALEC+=("$stalec"); R_STALECONF+=("$sconf")
  R_SEVCLS+=("$sevcls"); R_SEVHIT+=("$sevhit"); R_SEVANY+=("$sevany"); R_SEVCONF+=("$sevconf")
  R_BYTES+=("$bytes"); R_PRPRESENT+=("$prpresent"); R_PRID+=("$prid"); R_PROG+=("$prog"); R_PANE+=("$pane")
  R_NTASKS+=("$ntasks"); R_CANDS+=("$cands")
done <<< "$REC_ROWS"

ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }

wake_label() {  # <wakeKey>: main | routine | unmatched
  [ -n "${WK_SEEN[$1]:-}" ] || { echo unmatched; return; }
  if [ -n "${WK_CAPTAIN[$1]:-}" ]; then echo main; else echo routine; fi
}
wake_actionable() {  # <wakeKey>: captain label, backstop surfacing, a PR
  # reported in the joined rows, or - for a stale wake - a derivable repair
  if [ -n "${WK_CAPTAIN[$1]:-}" ] || [ -n "${WK_BACKSTOP[$1]:-}" ] || [ -n "${WK_PRROWS[$1]:-}" ]; then return 0; fi
  if [ -n "${WK_ISSTALE[$1]:-}" ]; then wake_stale_repair "$1"; return; fi
  return 1
}
wake_absorbable() {  # <wakeKey>: routine label and none of the actionable evidence
  [ "$(wake_label "$1")" = routine ] || return 1
  if wake_actionable "$1"; then return 1; fi
  return 0
}
task_poll_armed() {  # <task>: merge poll armed or pr= recorded (task-scoped, read at scoring time)
  local task=$1
  case "$task" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$STATE/$task.pr-poll" ] && return 0
  [ -f "$STATE/$task.meta" ] && grep -q '^pr=' "$STATE/$task.meta" 2>/dev/null
}
wake_pr_truth() {  # <wakeKey>: PR in the joined rows or a merge poll armed for one of its tasks
  [ -n "${WK_PRROWS[$1]:-}" ] && return 0
  local t
  for t in ${WK_TASKS[$1]:-}; do
    task_poll_armed "$t" && return 0
  done
  return 1
}
task_restarted_after() {  # <task> <epoch>: a worker incarnation newer than the wake
  local rec="$STATE/$1.busy-state" g
  case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$rec" ] || return 1
  g=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^gen=g?[0-9]+(\.|$)/) { sub(/^gen=g?/, "", $i); sub(/\..*$/, "", $i); print $i } }' "$rec")
  case "$g" in '' | *[!0-9]*) return 1 ;; esac
  [ "$g" -gt "$2" ]
}
wake_stale_repair() {  # <wakeKey>: a stale wake main had to act on - a worker
  # incarnation newer than the wake (a relaunch or replacement). A steer that
  # unsticks the worker without a restart, and a teardown (every task is torn
  # down once it finishes), are not derivable as repairs, so neither is claimed.
  local wk=$1 t epoch
  epoch=${WKEPOCH[$wk]:-}
  [ -n "$epoch" ] || return 1
  for t in ${WK_TASKS[$wk]:-}; do
    task_restarted_after "$t" "$epoch" && return 0
  done
  return 1
}

pane_of() {  # <record-idx>: pane identity from the facts
  [ "${R_PANE[$1]}" != "-" ] || return 1
  echo "${R_PANE[$1]}"
}

# Loss-class check for a stale-active-suppress fire: any later stale wake of
# the same pane inside the suppression window whose joined outcome was
# actionable - suppressing it would have swallowed a captain-facing wake.
stale_window_loss() {  # <record-idx>
  local i=$1 pane ep j panej epj
  pane=$(pane_of "$i") || return 1
  [ "${R_EPOCH[$i]}" != "-" ] || return 1
  ep=${R_EPOCH[$i]}
  for j in "${!R_WK[@]}"; do
    [ "$j" -ne "$i" ] || continue
    [ "${R_STALE[$j]}" = stale ] || continue
    panej=$(pane_of "$j") || continue
    [ "$panej" = "$pane" ] || continue
    [ "${R_EPOCH[$j]}" != "-" ] || continue
    epj=${R_EPOCH[$j]}
    [ "$epj" -gt "$ep" ] || continue
    [ "$epj" -le $((ep + STALE_SUPPRESS_WINDOW)) ] || continue
    if wake_actionable "${R_WK[$j]}"; then return 0; fi
  done
  return 1
}

# Gate fire conditions at floor $3 for record index $2. Callers gate on
# gate_apply first; these check only the firing condition itself.
gate_fire() {  # <gate> <record-idx> <floor>
  local gate=$1 i=$2 F=$3
  case "$gate" in
    absorb-no-new-outcome)
      [ "${R_NOUL[$i]}" != "-" ] && [ "${R_BYTES[$i]}" = 0 ] && ge "${R_NOUL[$i]}" "$F"
      ;;
    absorb-routine-working)
      [ "${R_ROUTE[$i]}" = routine ] && [ "${R_ROUTECONF[$i]}" != "-" ] && ge "${R_ROUTECONF[$i]}" "$F" || return 1
      case "${R_PHASE[$i]}" in working | no_change) ;; *) return 1 ;; esac
      [ "${R_PHASECONF[$i]}" != "-" ] && ge "${R_PHASECONF[$i]}" "$F"
      ;;
    stale-active-suppress)
      [ "${R_STALE[$i]}" = stale ] || return 1
      [ "${R_STALEC[$i]}" = active ] || return 1
      [ "${R_STALECONF[$i]}" != "-" ] && ge "${R_STALECONF[$i]}" "$F" || return 1
      [ "${R_PROG[$i]}" = true ]
      ;;
    pr-ready-arm)
      [ "${R_PHASE[$i]}" = finished_ready ] || return 1
      [ "${R_PHASECONF[$i]}" != "-" ] && ge "${R_PHASECONF[$i]}" "$F" || return 1
      [ "${R_PRPRESENT[$i]}" = true ]
      ;;
    severity-alert)
      [ "${R_SEVHIT[$i]}" = hit ] || return 1
      [ "${R_SEVCONF[$i]}" != "-" ] && ge "${R_SEVCONF[$i]}" "$F"
      ;;
    candidate-order)
      cand_order_eval "$i" "$F"
      [ -n "$CAND_HEAD" ]
      ;;
  esac
}

# Gate eligibility: exit 0 when the record's inputs let the gate fire and be
# judged; 1 when it must be counted unscorable; 2 when the gate does not apply
# (plain wake at a stale gate, single-task wake at the ordering gate) or the
# wake matches no outcome row.
gate_apply() {  # <gate> <record-idx>
  local gate=$1 i=$2
  [ -n "${WK_SEEN[${R_WK[$i]}]:-}" ] || return 2
  [ "${R_AVAIL[$i]}" = ok ] || return 1
  [ "${R_FACTS[$i]}" = facts ] || return 1
  case "$gate" in
    absorb-no-new-outcome)
      [ "${R_NOUL[$i]}" != "-" ] && [ "${R_BYTES[$i]}" != "-" ]
      ;;
    absorb-routine-working)
      [ "${R_ROUTE[$i]}" != "-" ] && [ "${R_ROUTECONF[$i]}" != "-" ] &&
        [ "${R_PHASE[$i]}" != "-" ] && [ "${R_PHASECONF[$i]}" != "-" ]
      ;;
    stale-active-suppress)
      [ "${R_STALE[$i]}" = stale ] || return 2
      [ "${R_STALEC[$i]}" != "-" ] && [ "${R_STALECONF[$i]}" != "-" ] && [ "${R_PROG[$i]}" != "-" ] && [ "${R_PANE[$i]}" != "-" ]
      ;;
    pr-ready-arm)
      [ "${R_PHASE[$i]}" != "-" ] && [ "${R_PHASECONF[$i]}" != "-" ] && [ "${R_PRPRESENT[$i]}" != "-" ]
      ;;
    severity-alert)
      [ "${R_SEVCLS[$i]}" != "-" ] && [ "${R_SEVCONF[$i]}" != "-" ] && [ "${R_SEVANY[$i]}" = any ]
      ;;
    candidate-order)
      [ "${R_NTASKS[$i]}" != "-" ] && [ "${R_NTASKS[$i]}" -ge 2 ] || return 2
      [ "${R_CANDS[$i]}" != "-" ]
      ;;
  esac
}

# Per-gate primary floor for a record: the record's own policy bands.
gate_policy_floor() {  # <gate> <record-idx>
  case "$1" in
    absorb-no-new-outcome | candidate-order) echo "${R_NPA[$2]}" ;;
    *) echo "${R_CF[$2]}" ;;
  esac
}

# candidate-order at floor $2 for record index $1: CAND_HEAD is the task the
# gate would report first ("" when it would absorb all candidates),
# CAND_DROPPED=1 when a captain-verdict candidate falls below the floor.
CAND_HEAD=''
CAND_DROPPED=0
cand_order_eval() {  # <record-idx> <floor>
  local i=$1 F=$2 c id val caps
  local -a parts=()
  CAND_HEAD=''
  CAND_DROPPED=0
  caps=" ${WK_CAPTASKS[${R_WK[$i]}]:-} "
  IFS=',' read -r -a parts <<< "${R_CANDS[$i]}"
  for c in "${parts[@]}"; do
    id=${c%%:*}
    val=${c#*:}
    if ge "$val" "$F"; then
      [ -z "$CAND_HEAD" ] && CAND_HEAD=$id
    else
      case "$caps" in *" $id "*) CAND_DROPPED=1 ;; esac
    fi
  done
}

GATES=(absorb-no-new-outcome absorb-routine-working stale-active-suppress pr-ready-arm severity-alert candidate-order)
declare -A ELIG=() UNSC=() UNSC_REASON=() FIRED=() CORRECT=() WRONG_DELAY=() WRONG_LOSS=() MISSED=() VDETAIL=()

for gate in "${GATES[@]}"; do
  for i in "${!R_WK[@]}"; do
    rc=0
    gate_apply "$gate" "$i" || rc=$?
    if [ "$rc" -eq 2 ]; then continue; fi
    if [ "$rc" -eq 1 ]; then
      UNSC[$gate]=$(( ${UNSC[$gate]:-0} + 1 ))
      if [ "${R_AVAIL[$i]}" = unavailable ]; then UNSC_REASON["$gate|$i"]="the shadow call was unavailable"
      else UNSC_REASON["$gate|$i"]="missing inputs for the gate"
      fi
      continue
    fi
    ELIG[$gate]=$(( ${ELIG[$gate]:-0} + 1 ))
    wk=${R_WK[$i]}
    if gate_fire "$gate" "$i" "$(gate_policy_floor "$gate" "$i")"; then
      FIRED[$gate]=$(( ${FIRED[$gate]:-0} + 1 ))
      case "$gate" in
        candidate-order)
          floor=$(gate_policy_floor "$gate" "$i")
          cand_order_eval "$i" "$floor"
          if [ "$CAND_DROPPED" -eq 1 ]; then
            WRONG_LOSS[$gate]=$(( ${WRONG_LOSS[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=loss
          elif [ "$CAND_HEAD" != "${WK_FIRST[$wk]:-}" ]; then
            WRONG_DELAY[$gate]=$(( ${WRONG_DELAY[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=delay
          else
            CORRECT[$gate]=$(( ${CORRECT[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=correct
          fi
          ;;
        stale-active-suppress)
          if stale_window_loss "$i"; then
            WRONG_LOSS[$gate]=$(( ${WRONG_LOSS[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=loss
          elif wake_actionable "$wk"; then
            WRONG_DELAY[$gate]=$(( ${WRONG_DELAY[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=delay
          else
            CORRECT[$gate]=$(( ${CORRECT[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=correct
          fi
          ;;
        pr-ready-arm)
          if wake_pr_truth "$wk"; then
            CORRECT[$gate]=$(( ${CORRECT[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=correct
          else
            WRONG_DELAY[$gate]=$(( ${WRONG_DELAY[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=delay
          fi
          ;;
        severity-alert)
          if wake_actionable "$wk"; then
            CORRECT[$gate]=$(( ${CORRECT[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=correct
          else
            WRONG_DELAY[$gate]=$(( ${WRONG_DELAY[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=delay
          fi
          ;;
        *)
          if wake_actionable "$wk"; then
            WRONG_LOSS[$gate]=$(( ${WRONG_LOSS[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=loss
          else
            CORRECT[$gate]=$(( ${CORRECT[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=correct
          fi
          ;;
      esac
    else
      # Missed: the branch absorbed the wake, the gate did not fire, and
      # firing would have been warranted for this gate.
      case "$gate" in
        absorb-no-new-outcome | absorb-routine-working)
          if wake_absorbable "$wk"; then MISSED[$gate]=$(( ${MISSED[$gate]:-0} + 1 )); VDETAIL["$gate|$i"]=missed; fi
          ;;
        stale-active-suppress)
          if wake_absorbable "$wk"; then MISSED[$gate]=$(( ${MISSED[$gate]:-0} + 1 )); VDETAIL["$gate|$i"]=missed; fi
          ;;
        pr-ready-arm)
          if [ "$(wake_label "$wk")" = routine ] && wake_pr_truth "$wk"; then MISSED[$gate]=$(( ${MISSED[$gate]:-0} + 1 )); VDETAIL["$gate|$i"]=missed; fi
          ;;
        severity-alert)
          if [ "$(wake_label "$wk")" = routine ] && wake_actionable "$wk"; then MISSED[$gate]=$(( ${MISSED[$gate]:-0} + 1 )); VDETAIL["$gate|$i"]=missed; fi
          ;;
        candidate-order)
          cand_order_eval "$i" "$(gate_policy_floor "$gate" "$i")"
          if [ "$CAND_DROPPED" -eq 1 ]; then
            # Absorb-all would have swallowed a captain-verdict candidate.
            WRONG_LOSS[$gate]=$(( ${WRONG_LOSS[$gate]:-0} + 1 ))
            VDETAIL["$gate|$i"]=loss
          fi
          ;;
      esac
    fi
  done
done

# Floor sweep: for each gate, the lowest floor in 0.70-0.99 with zero
# loss-class wrong fires, and the fire rate there.
SWEEP_OUT=''
for gate in "${GATES[@]}"; do
  if [ "${ELIG[$gate]:-0}" -eq 0 ]; then
    SWEEP_OUT="${SWEEP_OUT}| $gate | - | - | - |
"
    continue
  fi
  clean_floor='-'
  clean_fired='-'
  clean_rate='-'
  for ((fi = 70; fi <= 99; fi++)); do
    F=$(printf '0.%02d' "$fi")
    fired=0
    loss=0
    for i in "${!R_WK[@]}"; do
      gate_apply "$gate" "$i" || continue
      wk=${R_WK[$i]}
      if gate_fire "$gate" "$i" "$F"; then fired=$((fired + 1)); fi
      case "$gate" in
        candidate-order)
          cand_order_eval "$i" "$F"
          [ "$CAND_DROPPED" -eq 1 ] && loss=$((loss + 1))
          ;;
        stale-active-suppress)
          if gate_fire "$gate" "$i" "$F" && stale_window_loss "$i"; then loss=$((loss + 1)); fi
          ;;
        absorb-no-new-outcome | absorb-routine-working)
          if gate_fire "$gate" "$i" "$F" && wake_actionable "$wk"; then loss=$((loss + 1)); fi
          ;;
      esac
    done
    if [ "$loss" -eq 0 ]; then
      clean_floor=$F
      clean_fired=$fired
      clean_rate=$(awk -v a="$fired" -v b="${ELIG[$gate]}" 'BEGIN { printf "%.1f%%", 100 * a / b }')
      break
    fi
  done
  SWEEP_OUT="${SWEEP_OUT}| $gate | $clean_floor | $clean_fired | $clean_rate |
"
done

pct() {
  if [ "$2" -gt 0 ]; then printf '%d (%.1f%%)' "$1" "$(awk "BEGIN { print 100 * $1 / $2 }")"; else printf '0 (0.0%%)'; fi
}

printf '### candidate gates over full-variant shadow records (ground truth: joined branch outcomes, backstop surfacing, and derivable main actions)\n'
printf '| gate | eligible | unscorable | fired | correct | wrong (delay-only) | wrong (loss) | missed (absorbed, gate silent) |\n|---|---|---|---|---|---|---|---|\n'
for gate in "${GATES[@]}"; do
  miss='-'
  [ "$gate" != candidate-order ] && miss="${MISSED[$gate]:-0}"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' "$gate" \
    "${ELIG[$gate]:-0}" "${UNSC[$gate]:-0}" "${FIRED[$gate]:-0}" \
    "$(pct "${CORRECT[$gate]:-0}" "${FIRED[$gate]:-0}")" \
    "${WRONG_DELAY[$gate]:-0}" "${WRONG_LOSS[$gate]:-0}" "$miss"
done
unmatched=0
for i in "${!R_WK[@]}"; do
  [ -n "${WK_SEEN[${R_WK[$i]}]:-}" ] || unmatched=$((unmatched + 1))
done
if [ "$unmatched" -gt 0 ]; then
  word=records
  [ "$unmatched" -eq 1 ] && word=record
  printf 'unmatched (no outcome row carries this wake key; never counted as a verdict): %s %s\n' "$unmatched" "$word"
fi
printf '\n### floor sweep 0.70-0.99: lowest floor with zero loss-class wrong fires, and the fire rate there\n'
printf '| gate | lowest clean floor | fires there | fire rate there |\n|---|---|---|---|\n'
printf '%s' "$SWEEP_OUT"

if [ "$VERBOSE" = 1 ]; then
  printf '\n# wakeKey\tgate\tverdict\tdetail\n'
  for i in "${!R_WK[@]}"; do
    for gate in "${GATES[@]}"; do
      v=${VDETAIL["$gate|$i"]:-}
      [ -n "$v" ] || continue
      detail=''
      case "$gate" in
        stale-active-suppress) detail="pane=$(pane_of "$i" 2>/dev/null || echo '-') window=${STALE_SUPPRESS_WINDOW}s" ;;
        candidate-order) detail="candidates=${R_CANDS[$i]} first_reported=${WK_FIRST[${R_WK[$i]}]:--}" ;;
        pr-ready-arm) detail="pr=${R_PRID[$i]}" ;;
        severity-alert) detail="class=${R_SEVCLS[$i]}" ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "${R_WK[$i]}" "$gate" "$v" "$detail"
    done
  done
  printf '\n# wakeKey\tgate\trecord\tunscorable-reason\n'
  for k in "${!UNSC_REASON[@]}"; do
    ri=${k#*|}
    printf '%s\t%s\t%s\t%s\n' "${R_WK[$ri]:-}" "${k%%|*}" "$ri" "${UNSC_REASON[$k]}"
  done
fi
exit 0
