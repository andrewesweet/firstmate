#!/usr/bin/env bash
# fm-branch-shadow-score.sh - retrospective score of the Claude Code
# supervision-branch mod's shadow advisory trial (docs/claude-supervision-branch.md).
#
# Reads state/branch-mod-shadow.jsonl, the durable log the mod appends one
# record per ablation variant per granted wake to, and joins every record to
# the branch's own durable verdict in state/branch-outcomes.jsonl by exact
# wake identity (the record's wake string equals the outcome row's wake).
# Only the route question has that durable label: a wake whose joined rows
# include a captain verdict is labelled main, a wake whose joined rows are
# all routine is labelled routine. The other questions (phase, severity,
# no_new_outcome, stale_state, per-candidate Nouls) have no durable label in
# the outcome record, so the scorer prints their answer distribution and
# policy-uncertainty columns only; -v dumps the per-wake join for manual
# adjudication.
#
# Policy bands (recorded in every shadow record): a Choice answer counts only
# at confidence >= 0.85; a Noul grants below 0.15 and passes above 0.85 and
# is uncertain between the two. The repeat-control pair (the full variant run
# twice on every tenth wake) is scored per question as raw call noise.
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
    -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$arg") ;;
  esac
done
LOG=${args[0]:-$STATE/branch-mod-shadow.jsonl}
OUTCOMES=${args[1]:-$STATE/branch-outcomes.jsonl}
command -v jq >/dev/null 2>&1 || { echo "fm-branch-shadow-score: jq is required" >&2; exit 2; }

# Route label per outcome wake: main when any joined row is a captain verdict,
# routine when the wake joined only routine rows.
OUTCOME_ROWS=''
if [ -f "$OUTCOMES" ]; then
  OUTCOME_ROWS=$(jq -r '[(.wake // ""), (.verdict // "")] | @tsv' "$OUTCOMES" 2>/dev/null || true)
fi
declare -A WAKE_CAPTAIN=() WAKE_ROWS=()
while IFS=$'\t' read -r wake verdict; do
  [ -n "$wake" ] || continue
  WAKE_ROWS[$wake]=1
  [ "$verdict" = captain ] && WAKE_CAPTAIN[$wake]=1
done <<< "$OUTCOME_ROWS"

# One line per record question:
# wake <TAB> variant <TAB> repeat <TAB> question <TAB> raw <TAB> policy <TAB> unavailable
if [ ! -f "$LOG" ]; then
  printf '### route (label: the joined branch outcome verdict)\n| variant | scored | raw agreement | policy agreement | confident disagreement | uncertain | unavailable |\n|---|---|---|---|---|---|---|\n'
  exit 0
fi
ROWS=$(jq -r '
  def pol:
    if .type == "noul" then
      [(if (.noul // 0) >= 0.5 then "true" else "false" end),
       (if (.noul // -1) < 0.15 then "false" elif (.noul // -1) > 0.85 then "true" else "uncertain" end)]
    elif .type == "choice" then
      [(.choice // "?"), (if (.confidence // 0) < 0.85 then "uncertain" else (.choice // "?") end)]
    elif .type == "score" then
      [((.score // "?") | tostring), (if (.confidence // 0) < 0.85 then "uncertain" else ((.score // "?") | tostring) end)]
    else ["?", "uncertain"] end;
  . as $r |
  (if .unavailable != null then
    [[$r.wake, $r.variant, ($r.repeat | tostring), "UNAVAILABLE", "-", "-", $r.unavailable] | @tsv]
  else
    [$r.answers // {} | to_entries |
      map(if .key == "candidates" and (.value | type == "object") then
            .value | to_entries | map({key: ("candidates." + .key), value: .value})
          else [.] end) | flatten |
      (if length == 0 then [{key: "NO_ANSWERS", value: {}}] else . end)[] |
      (.value | pol) as $p |
      [$r.wake, $r.variant, ($r.repeat | tostring), .key, $p[0], $p[1], "-"] | @tsv]
  end) | .[]' "$LOG")

declare -A SEEN_Q=() RAW=() POL=() DIS=() UNC=() SCORED=() TOT=() UNAV=() ANSWERS=() CTRL1=() CTRL2=()
QORDER=()

note_q() {  # <question>: remember first-seen order
  [ -n "${SEEN_Q[$1]:-}" ] && return 0
  SEEN_Q[$1]=1
  QORDER+=("$1")
}

while IFS=$'\t' read -r wake variant repeat q raw pol unav; do
  [ -n "$wake" ] || continue
  if [ "$q" = UNAVAILABLE ]; then
    UNAV[$variant]=$(( ${UNAV[$variant]:-0} + 1 ))
    continue
  fi
  [ "$q" = NO_ANSWERS ] && continue
  note_q "$q"
  k="$q|$variant"
  TOT[$k]=$(( ${TOT[$k]:-0} + 1 ))
  ANSWERS["$k|$raw"]=$(( ${ANSWERS["$k|$raw"]:-0} + 1 ))
  label=''
  if [ "$q" = route ]; then
    if [ -n "${WAKE_CAPTAIN[$wake]:-}" ]; then label=main
    elif [ -n "${WAKE_ROWS[$wake]:-}" ]; then label=routine
    fi
  fi
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
  # Repeat control: the two full-variant calls of one wake, per question.
  if [ "$variant" = full ]; then
    case "$repeat" in
      1) CTRL1["$wake|$q"]=$raw ;;
      2) CTRL2["$wake|$q"]=$raw ;;
    esac
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
    else lbl=unlabeled
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$wake" "$lbl" "$variant" "$q" "$raw" "$pol" "$unav"
  done
  printf '\n'
fi

for q in "${QORDER[@]}"; do
  case "$q" in
    full | without_current_state | without_prior_outcomes | without_pane_tail) continue ;;
  esac
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
    case "$q" in
      full | without_current_state | without_prior_outcomes | without_pane_tail | UNAVAILABLE | NO_ANSWERS) continue ;;
    esac
    IFS=$'\t' read -r cq pairs same < <(control_pairs "$q")
    [ "${pairs:-0}" -gt 0 ] || continue
    printf '| %s | %s | %s |\n' "$cq" "$pairs" "$same"
  done
fi
exit 0
