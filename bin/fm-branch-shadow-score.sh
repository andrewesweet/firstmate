#!/usr/bin/env bash
# fm-branch-shadow-score.sh - retrospective score of the supervision-branch
# shadow advisory trial on either host (docs/claude-supervision-branch.md
# "Shadow advisory trial"; docs/pi-supervision-branch.md for the Pi extension).
#
# Reads state/branch-mod-shadow.jsonl, the durable log each host appends one
# record per ablation variant per granted wake to, and joins every record to
# the branch's own durable verdict in state/branch-outcomes.jsonl by the
# durable wake identity: the mod stamps the same wakeKey (its wake-queue
# "epoch:seq" set) onto the shadow records and onto the outcome row it writes
# for that wake. A record whose wakeKey is empty or matches no outcome row is
# reported as unmatched, separately, and never counted as a verdict; -v dumps
# the per-wake join for manual adjudication. Only the route question has a
# durable label: a wake whose joined rows include a captain verdict is
# labelled main, a wake whose joined rows are all routine is labelled routine.
# The other questions (phase, severity, no_new_outcome, stale_state,
# per-candidate Nouls) have no durable label in the outcome record, so the
# scorer prints their answer distribution and policy-uncertainty columns
# only.
#
# Policy bands are read from each record's policy object (a Choice answer
# counts only at confidence >= choice_confidence_floor; a Noul grants below
# noul_grant_below, passes above noul_pass_above and is uncertain between the
# two), with 0.85 / 0.15 / 0.85 as fallbacks. The repeat-control pair (the full
# variant run twice on every tenth wake) is scored per question as raw call
# noise only; the per-variant tallies skip the repeat so the full row stays one
# sample per wake, like every ablation row. A final cost section meters the
# trial: per variant the record count, records carrying the shim's usage
# object, input/output token totals and latency p50/p95 over every record
# (unavailable calls still cost time), plus one summed line per granted wake
# key (records without a wake key are excluded there). A torn or malformed
# log line is skipped, never fatal.
#
# Usage:
#   bin/fm-branch-shadow-score.sh [-v] [<shadow-log>] [<outcomes-file>]
#
# The logs default to $STATE/branch-mod-shadow.jsonl and
# $STATE/branch-outcomes.jsonl. Exit 0 always; the tables are the result, and
# an absent shadow log prints only the empty tables.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
_fm_wake_require_classify

VERBOSE=0
args=()
for arg in "$@"; do
  case "$arg" in
    -v) VERBOSE=1 ;;
    -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$arg") ;;
  esac
done
LOG=${args[0]:-$STATE/branch-mod-shadow.jsonl}
OUTCOMES=${args[1]:-$STATE/branch-outcomes.jsonl}
command -v jq >/dev/null 2>&1 || { echo "fm-branch-shadow-score: jq is required" >&2; exit 2; }

# Route label per outcome wakeKey: main when any joined row is a captain
# verdict, routine when the wakeKey joined only routine rows.
OUTCOME_ROWS=''
if [ -f "$OUTCOMES" ]; then
  # "-" marks an absent key: a real wake key is only digits, colon and comma
  # (validated at write time), and a leading empty @tsv field would collapse
  # under `read`. The raw read also skips torn or malformed lines so one bad
  # outcome row can never drop the labels of every row after it.
  OUTCOME_ROWS=$(jq -R -r 'fromjson? | select(type == "object") | [(.wakeKey // "" | if . == "" then "-" else . end), (.verdict // "")] | @tsv' "$OUTCOMES" 2>/dev/null || true)
fi
declare -A WAKE_CAPTAIN=() WAKE_ROWS=()
while IFS=$'\t' read -r wake verdict; do
  { [ -n "$wake" ] && [ "$wake" != "-" ]; } || continue
  WAKE_ROWS[$wake]=1
  [ "$verdict" = captain ] && WAKE_CAPTAIN[$wake]=1
done <<< "$OUTCOME_ROWS"

# One line per record question:
# wake <TAB> variant <TAB> repeat <TAB> question <TAB> raw <TAB> policy <TAB> unavailable
if [ ! -f "$LOG" ]; then
  printf '### route (label: the joined branch outcome verdict)\n| variant | scored | raw agreement | policy agreement | confident disagreement | uncertain | unavailable |\n|---|---|---|---|---|---|---|\n'
  exit 0
fi
ROWS=$(jq -R -r '
  fromjson? | select(type == "object") | . as $r |
  (($r.policy // {}) | (.choice_confidence_floor // 0.85)) as $cf |
  (($r.policy // {}) | (.noul_grant_below // 0.15)) as $gb |
  (($r.policy // {}) | (.noul_pass_above // 0.85)) as $pa |
  def pol:
    if .type == "noul" then
      [(if (.noul // 0) >= 0.5 then "true" else "false" end),
       (if (.noul // -1) < $gb then "false" elif (.noul // -1) > $pa then "true" else "uncertain" end)]
    elif .type == "choice" then
      [(.choice // "?"), (if (.confidence // 0) < $cf then "uncertain" else (.choice // "?") end)]
    elif .type == "score" then
      [((.score // "?") | tostring), (if (.confidence // 0) < $cf then "uncertain" else ((.score // "?") | tostring) end)]
    else ["?", "uncertain"] end;
  (if .unavailable != null then
    [[($r.wakeKey // "" | if . == "" then "-" else . end), $r.variant, ($r.repeat | tostring), "UNAVAILABLE", "-", "-", $r.unavailable] | @tsv]
  else
    [$r.answers // {} | to_entries |
      map(if (.key | startswith("candidate:")) then
            [{key: ("candidates." + (.key | ltrimstr("candidate:"))), value: .value}]
          else [.] end) | flatten |
      (if length == 0 then [{key: "NO_ANSWERS", value: {}}] else . end)[] |
      (.value | pol) as $p |
      [($r.wakeKey // "" | if . == "" then "-" else . end), $r.variant, ($r.repeat | tostring), .key, $p[0], $p[1], "-"] | @tsv]
  end) | .[]' "$LOG")

declare -A SEEN_Q=() RAW=() POL=() DIS=() UNC=() SCORED=() TOT=() UNAV=() ANSWERS=() CTRL1=() CTRL2=() SEEN_REC=() UNMATCHED=()
QORDER=()

note_q() {  # <question>: remember first-seen order
  [ -n "${SEEN_Q[$1]:-}" ] && return 0
  SEEN_Q[$1]=1
  QORDER+=("$1")
}

while IFS=$'\t' read -r wake variant repeat q raw pol unav; do
  [ -n "$wake" ] || continue
  # Repeat control: the two full-variant calls of one wake, per question. The
  # repeat itself is not a per-variant sample.
  if [ "$q" != UNAVAILABLE ] && [ "$q" != NO_ANSWERS ] && [ "$variant" = full ]; then
    case "$repeat" in
      1) CTRL1["$wake|$q"]=$raw ;;
      2) CTRL2["$wake|$q"]=$raw ;;
    esac
  fi
  [ "$repeat" -gt 1 ] && continue
  # Unmatched records: the wake key is absent ("-") or no outcome row carries
  # it. Counted once per record, reported separately, never counted as a
  # verdict.
  if [ -z "${SEEN_REC["$wake|$variant"]:-}" ]; then
    SEEN_REC["$wake|$variant"]=1
    if [ "$q" != UNAVAILABLE ] && [ -z "${WAKE_ROWS[$wake]:-}" ]; then
      UNMATCHED[$variant]=$(( ${UNMATCHED[$variant]:-0} + 1 ))
    fi
  fi
  if [ "$q" = UNAVAILABLE ]; then
    UNAV[$variant]=$(( ${UNAV[$variant]:-0} + 1 ))
    continue
  fi
  [ "$q" = NO_ANSWERS ] && continue
  note_q "$q"
  label=''
  if [ "$q" = route ]; then
    if [ -n "${WAKE_CAPTAIN[$wake]:-}" ]; then label=main
    elif [ -n "${WAKE_ROWS[$wake]:-}" ]; then label=routine
    fi
    # An unmatched route record has no durable verdict: already reported in
    # the unmatched note, never counted as a route sample.
    [ -n "$label" ] || continue
  fi
  k="$q|$variant"
  TOT[$k]=$(( ${TOT[$k]:-0} + 1 ))
  ANSWERS["$k|$raw"]=$(( ${ANSWERS["$k|$raw"]:-0} + 1 ))
  if [ -n "$label" ]; then
    SCORED[$k]=$(( ${SCORED[$k]:-0} + 1 ))
    [ "$raw" = "$label" ] && RAW[$k]=$(( ${RAW[$k]:-0} + 1 ))
    if [ "$pol" != uncertain ]; then
      if [ "$pol" = "$label" ]; then POL[$k]=$(( ${POL[$k]:-0} + 1 )); else DIS[$k]=$(( ${DIS[$k]:-0} + 1 )); fi
    else
      UNC[$k]=$(( ${UNC[$k]:-0} + 1 ))
    fi
  else
    [ "$pol" = uncertain ] && UNC[$k]=$(( ${UNC[$k]:-0} + 1 ))
  fi
done <<< "$ROWS"

pct() {  # <part> <whole>
  if [ "$2" -gt 0 ]; then printf '%d (%.1f%%)' "$1" "$(awk "BEGIN { print 100 * $1 / $2 }")"; else printf '0 (0.0%%)'; fi
}

VARIANTS=(full without_current_state without_prior_outcomes without_pane_tail)
control_pairs() {  # <question>: count full repeat pairs
  local pairs=0 same=0 wake q
  for wk in "${!CTRL1[@]}"; do
    case "$wk" in *"|$1") : ;; *) continue ;; esac
    q="$1"
    wake=${wk%"|$q"}
    [ -n "${CTRL2[$wake|$q]:-}" ] || continue
    pairs=$(( pairs + 1 ))
    [ "${CTRL1[$wk]}" = "${CTRL2[$wake|$q]}" ] && same=$(( same + 1 ))
  done
  printf '%s\t%s\t%s\n' "$q" "$pairs" "$same"
}

if [ "$VERBOSE" = 1 ]; then
  printf '# wake\tlabel\tvariant\tquestion\traw\tpolicy\tunavailable\n'
  printf '%s\n' "$ROWS" | while IFS=$'\t' read -r wake variant repeat q raw pol unav; do
    [ -n "$wake" ] || continue
    if [ -n "${WAKE_CAPTAIN[$wake]:-}" ]; then lbl=main
    elif [ -n "${WAKE_ROWS[$wake]:-}" ]; then lbl=routine
    else lbl=unmatched
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$wake" "$lbl" "$variant" "$q" "$raw" "$pol" "$unav"
  done
  printf '\n'
fi

for q in "${QORDER[@]}"; do
  if [ "$q" = route ]; then
    printf '### route (label: the joined branch outcome verdict)\n'
    printf '| variant | scored | raw agreement | policy agreement | confident disagreement | uncertain | unavailable |\n|---|---|---|---|---|---|---|\n'
    for v in "${VARIANTS[@]}"; do
      k="$q|$v"
      [ -n "${TOT[$k]:-}" ] || [ -n "${UNAV[$v]:-}" ] || continue
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$v" \
        "${SCORED[$k]:-0}/${TOT[$k]:-0}" \
        "$(pct "${RAW[$k]:-0}" "${SCORED[$k]:-0}")" \
        "$(pct "${POL[$k]:-0}" "${SCORED[$k]:-0}")" \
        "${DIS[$k]:-0}" \
        "$(pct "${UNC[$k]:-0}" "${TOT[$k]:-0}")" \
        "${UNAV[$v]:-0}"
    done
    unmatched=''
    for v in "${VARIANTS[@]}"; do
      [ -n "${UNMATCHED[$v]:-}" ] && unmatched="$unmatched $v=${UNMATCHED[$v]}"
    done
    [ -n "$unmatched" ] && printf 'unmatched (no outcome row carries this wake key; never counted as a verdict):%s\n' "$unmatched"
  else
    printf '### %s (no durable label in the outcome record; distribution and policy uncertainty only)\n' "$q"
    printf '| variant | records | answers | uncertain | unavailable |\n|---|---|---|---|---|\n'
    for v in "${VARIANTS[@]}"; do
      k="$q|$v"
      [ -n "${TOT[$k]:-}" ] || [ -n "${UNAV[$v]:-}" ] || continue
      dist=''
      for a in "${!ANSWERS[@]}"; do
        case "$a" in
          "$k"*) dist="$dist ${a#"$k|"}=${ANSWERS[$a]}" ;;
        esac
      done
      printf '| %s | %s |%s | %s | %s |\n' "$v" "${TOT[$k]:-0}" "$dist" "$(pct "${UNC[$k]:-0}" "${TOT[$k]:-0}")" "${UNAV[$v]:-0}"
    done
  fi
  printf '\n'
done
if [ "${#CTRL1[@]}" -gt 0 ]; then
  printf '### repeat control (full variant run twice on one wake; raw call agreement)\n'
  printf '| question | full pairs | identical answers |\n|---|---|---|\n'
  for q in "${QORDER[@]}"; do
    IFS=$'\t' read -r cq pairs same < <(control_pairs "$q")
    [ "${pairs:-0}" -gt 0 ] || continue
    printf '| %s | %s | %s |\n' "$cq" "$pairs" "$same"
  done
fi

# ---------- cost: the metered Jev usage and latency per variant ----------------
# Token fields are the API's own usage object the shim passed through;
# latency is every record's ms, so unavailable calls still cost time.
rank_pick() {  # <percent> <sorted numbers...>: nearest-rank percentile
  local p=$1; shift
  local n=$#
  [ "$n" -gt 0 ] || { printf '0'; return 0; }
  local rank=$(( (p * n + 99) / 100 ))
  [ "$rank" -lt 1 ] && rank=1
  [ "$rank" -gt "$n" ] && rank=$n
  shift $(( rank - 1 ))
  printf '%s' "$1"
}
COST_TSV=$(jq -R -r '
  fromjson? | select(type == "object") |
  [(if (.wakeKey // "") == "" then "-" else .wakeKey end),
   (.variant // "?"),
   (if (.usage | type) == "object" and (.usage.input_tokens | type) == "number" then (.usage.input_tokens | tostring) else "-" end),
   (if (.usage | type) == "object" and (.usage.output_tokens | type) == "number" then (.usage.output_tokens | tostring) else "-" end),
   (if (.ms | type) == "number" then (.ms | tostring) else "-" end)] | @tsv' "$LOG")
declare -A COST_N=() COST_IN_N=() COST_IN_SUM=() COST_OUT_SUM=() COST_MS_LIST=()
declare -A WAKE_IN=() WAKE_OUT=() WAKE_N=()
while IFS=$'\t' read -r cwake cvariant cin cout cms; do
  [ -n "$cwake" ] || continue
  COST_N[$cvariant]=$(( ${COST_N[$cvariant]:-0} + 1 ))
  [ "$cwake" != "-" ] && WAKE_N[$cwake]=$(( ${WAKE_N[$cwake]:-0} + 1 ))
  if [ "$cms" != "-" ]; then
    COST_MS_LIST[$cvariant]+="$cms"$'\n'
  fi
  if [ "$cin" != "-" ]; then
    COST_IN_N[$cvariant]=$(( ${COST_IN_N[$cvariant]:-0} + 1 ))
    COST_IN_SUM[$cvariant]=$(( ${COST_IN_SUM[$cvariant]:-0} + cin ))
    [ "$cwake" != "-" ] && WAKE_IN[$cwake]=$(( ${WAKE_IN[$cwake]:-0} + cin ))
  fi
  if [ "$cout" != "-" ]; then
    COST_OUT_SUM[$cvariant]=$(( ${COST_OUT_SUM[$cvariant]:-0} + cout ))
    [ "$cwake" != "-" ] && WAKE_OUT[$cwake]=$(( ${WAKE_OUT[$cwake]:-0} + cout ))
  fi
done <<< "$COST_TSV"
printf '### cost (metered Jev usage the shim passed through; latency over every record, unavailable calls included)\n'
printf '| variant | records | with usage | input tokens total | output tokens total | latency p50 ms | latency p95 ms |\n|---|---|---|---|---|---|---|\n'
for v in "${VARIANTS[@]}"; do
  [ -n "${COST_N[$v]:-}" ] || continue
  ms_sorted=()
  [ -n "${COST_MS_LIST[$v]:-}" ] && mapfile -t ms_sorted < <(printf '%s' "${COST_MS_LIST[$v]}" | sort -n)
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$v" \
    "${COST_N[$v]}" "${COST_IN_N[$v]:-0}" "${COST_IN_SUM[$v]:-0}" \
    "${COST_OUT_SUM[$v]:-0}" "$(rank_pick 50 "${ms_sorted[@]}")" "$(rank_pick 95 "${ms_sorted[@]}")"
done
if [ "${#WAKE_N[@]}" -gt 0 ]; then
  printf 'per granted wake (all variants of one wake key summed; records without a wake key excluded):\n'
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    printf 'wake %s: input=%s output=%s records=%s\n' "$w" "${WAKE_IN[$w]:-0}" "${WAKE_OUT[$w]:-0}" "${WAKE_N[$w]}"
  done < <(printf '%s\n' "${!WAKE_N[@]}" | LC_ALL=C sort)
fi
exit 0
