#!/usr/bin/env bash
# fm-dispatch-resolve-score.sh - offline replay scorer for typed dispatch resolution.
#
# Usage:
#   fm-dispatch-resolve-score.sh [--labels <file>]
#
# Pure bash and jq: no network, no key, never touches the live resolver, and
# never changes its selection, floor, output block, or outcome-log shape.
# docs/configuration.md "Typed dispatch resolution" owns the operator contract;
# this header owns the exact flags, join, and metric definitions.
#
# Inputs: the resolver outcome log $FM_HOME/data/dispatch-resolve.jsonl and the
#   actually-dispatched profile log $FM_HOME/data/dispatch-spawns.jsonl, written
#   by bin/fm-dispatch-resolve.sh and bin/fm-spawn.sh. FM_DISPATCH_RESOLVE_LOG
#   and FM_DISPATCH_SPAWNS_LOG override both paths for tests. A missing log is
#   zero records, never an error: a missing spawns log reports coverage 0.
#   Adjudicated labels are captain-private and live in data/, never tracked;
#   this tool only consumes the given labels file, one
#   `<task><TAB><rule when text>` per line, blank lines and `#` comments
#   ignored. It never runs the resolver against retained briefs.
#
# Join: each spawn row joins the latest resolver row for the same task whose ts
#   is at or before the spawn ts, so a task resolved twice is judged on the
#   record its spawn could have seen. Timestamps compare as UTC ISO 8601.
#   A resolver `profile` line parses as `--harness h [--model m] [--effort e]`
#   with @sh quoting; an absent model or effort reads as "default", matching
#   fm-spawn.sh's task-record normalization.
#
# Metrics, printed on stdout:
#   coverage: distinct spawned tasks with a joined resolver record, over all
#     distinct spawned tasks.
#   clear_joined: joined (spawn, resolver) pairs whose resolver status is clear.
#   profile_agreement: clear pairs whose resolver profile equals the spawned
#     harness, model, and effort.
#   override_rate: clear pairs whose spawn differs from the resolver profile.
#   rule_agreement (labels only): clear pairs whose task carries a label and
#     whose resolver selected_option equals that label.
#   floors: for each floor 0.3 to 0.9 by 0.1 (the live 0.6 floor marked with
#     `*`), over every resolver record with a numeric confidence, a record
#     counting as clear at floor f when its confidence is at or above f:
#     clear_frac is the fraction of records clear at f; precision_vs_label
#     (labels only) is the fraction of labelled records clear at f whose
#     selected_option equals the label; precision_vs_spawn is the profile
#     agreement of the clear, spawn-joined pairs at or above f. Below the live
#     floor precision_vs_spawn prints n/a: no task was ever dispatched on a
#     sub-floor pick, so no spawn evidence exists there.
#   Fractions print with four decimals; a zero denominator prints n/a.
#
# Exit 0 with the report; exit 2 only for an unreadable input (an unreadable or
# malformed log or labels file).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

LABELS=''
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
    --*) die "--$want_value needs a value" ;;
    esac
    LABELS=$a
    want_value=
    continue
  fi
  case "$a" in
  --labels) want_value=labels ;;
  -h | --help) usage; exit 0 ;;
  -*) die "unknown flag $a" ;;
  *) die "unexpected argument $a" ;;
  esac
done
[ -z "$want_value" ] || die "--$want_value needs a value"

RESOLVE_LOG="${FM_DISPATCH_RESOLVE_LOG:-$FM_HOME/data/dispatch-resolve.jsonl}"
SPAWNS_LOG="${FM_DISPATCH_SPAWNS_LOG:-$FM_HOME/data/dispatch-spawns.jsonl}"
command -v jq >/dev/null 2>&1 || die "jq required"

# Labels: one <task><TAB><rule when text> per line; blanks and # comments ignored.
if [ -n "$LABELS" ]; then
  [ -r "$LABELS" ] || die "labels file not readable: $LABELS"
  LABELS_JSON=$(jq -R -s '
    split("\n")
    | map(select(test("^\\s*(#|$)") | not))
    | map(split("\t"))
    | (if any(.[]; length < 2 or .[0] == "" or ((.[1:] | join("\t")) == ""))
       then error("bad labels") else . end)
    | map({key: .[0], value: (.[1:] | join("\t"))})
    | from_entries' "$LABELS") || die "malformed labels file: $LABELS (one <task><TAB><rule when text> per line)"
else
  LABELS_JSON='{}'
fi

WORK=$(mktemp -d) || die "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT

# read_log <path> <kind>: writes a validated JSON array to $WORK/<kind>.json;
# a missing path is []. Any malformed line (bad JSON, bad shape, bad timestamp)
# fails the whole read. The array goes to jq as a file, never as an argument,
# so a log of any size scores.
read_log() {
  local path=$1 kind=$2 filter
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '[]\n' > "$WORK/$kind.json"
    return 0
  fi
  [ -r "$path" ] || die "$kind log not readable: $path"
  if [ "$kind" = resolve ]; then
    filter='
      split("\n") | map(select(test("^\\s*$") | not))
      | map(fromjson)
      | (if any(.[]; type != "object") then error("not an object") else . end)
      | map(. + {_epoch: (.ts | try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch "BAD")})
      | (if any(.[];
            ._epoch == "BAD" or (._epoch | type) != "number"
            or (.task != null and ((.task | type) != "string" or .task == ""))
            or ((.status | type) != "string")
            or (.confidence != null and ((.confidence | type) != "number"))
            or (.rule != null and ((.rule | type) != "string"))
            or (.profile != null and ((.profile | type) != "string"))
            or (.selected_option != null and ((.selected_option | type) != "string")))
         then error("bad resolve record") else . end)'
  else
    filter='
      split("\n") | map(select(test("^\\s*$") | not))
      | map(fromjson)
      | (if any(.[]; type != "object") then error("not an object") else . end)
      | map(. + {_epoch: (.ts | try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch "BAD")})
      | (if any(.[];
            ._epoch == "BAD" or (._epoch | type) != "number"
            or ((.task | type) != "string" or .task == "")
            or ((.harness | type) != "string" or .harness == "")
            or (.kind != null and ((.kind | type) != "string"))
            or (.model != null and ((.model | type) != "string"))
            or (.effort != null and ((.effort | type) != "string")))
         then error("bad spawn record") else . end)'
  fi
  jq -R -s "$filter" "$path" > "$WORK/$kind.json" || die "malformed $kind log: $path (one JSON object per line with a UTC ISO-8601 ts)"
}

read_log "$RESOLVE_LOG" resolve
read_log "$SPAWNS_LOG" spawns

# The join and every metric live in this one jq program; bash only formats.
# shellcheck disable=SC2016  # the jq program's $names are jq variables, not shell expansions.
SUMMARY=$(jq -cn --slurpfile resolve "$WORK/resolve.json" --slurpfile spawns "$WORK/spawns.json" \
  --argjson labels "$LABELS_JSON" '
  def norm: if . == null or . == "" then "default" else . end;
  def sh_unescape: gsub("\u0027\\\\\u0027\u0027"; "\u0027");
  def prof_key($k): (capture("--" + $k + " \u0027(?<v>([^\u0027]|\u0027\\\\\u0027\u0027)*)\u0027") | .v)? | select(. != null) | sh_unescape;
  def profile_agrees:
    ([.resolver.profile | prof_key("harness")][0]) as $h
    | ([.resolver.profile | prof_key("model")][0] | norm) as $m
    | ([.resolver.profile | prof_key("effort")][0] | norm) as $e
    | ($h != null and $h == .harness and $m == (.model | norm) and $e == (.effort | norm));
  def labelled($L): .task != null and ($L[.task] // "") != "";
  def label_agrees($L): $L[.task] == .selected_option;
  ($resolve[0]) as $R | ($spawns[0]) as $S | ($labels) as $L | 0.6 as $live
  | ([$S[] | . as $s | $s + {resolver: ([$R[] | select(.task != null and .task == $s.task and ._epoch <= $s._epoch)] | max_by(._epoch))}]) as $J
  | ([$J[] | .task] | unique) as $tasks
  | ([$J[] | select(.resolver != null) | .task] | unique) as $covered
  | ([$J[] | select(.resolver != null and .resolver.status == "clear")]) as $C
  | ([$C[] | select(profile_agrees)]) as $A
  | ([$C[] | select(.resolver | labelled($L))]) as $LN
  | ([$LN[] | select(.resolver | label_agrees($L))]) as $LG
  | ([$R[] | select((.confidence | type) == "number")]) as $P
  | {
      resolve_records: ($R | length), spawn_records: ($S | length),
      spawned_tasks: ($tasks | length), covered_tasks: ($covered | length),
      clear_joined: ($C | length), agree: ($A | length),
      label_n: ($LN | length), label_agree: ($LG | length), pop: ($P | length),
      floors: [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9 | . as $f
        | ([$P[] | select(.confidence >= $f)]) as $wc
        | ([$C[] | select($f >= $live and .resolver.confidence >= $f)]) as $cp
        | ([$wc[] | select(labelled($L))]) as $ln
        | ([$ln[] | select(label_agrees($L))]) as $lg
        | {floor: $f, live: ($f == $live), wc: ($wc | length),
           prec_n: (if $f >= $live then ($cp | length) else null end),
           prec_agree: ([$cp[] | select(profile_agrees)] | length),
           lab_n: ($ln | length), lab_agree: ($lg | length)}]
    }') || die "scoring failed"

fmt_frac() {  # <num> <den>: four decimals, or n/a on a zero denominator.
  if [ "$2" -eq 0 ]; then
    printf 'n/a'
  else
    awk -v n="$1" -v d="$2" 'BEGIN { printf "%.4f", n / d }'
  fi
}
fmt_floor() {  # %g without trailing zeros.
  awk -v f="$1" 'BEGIN { printf "%g", f }'
}

resolve_records=$(jq -r .resolve_records <<<"$SUMMARY")
spawn_records=$(jq -r .spawn_records <<<"$SUMMARY")
spawned_tasks=$(jq -r .spawned_tasks <<<"$SUMMARY")
covered_tasks=$(jq -r .covered_tasks <<<"$SUMMARY")
clear_joined=$(jq -r .clear_joined <<<"$SUMMARY")
agree=$(jq -r .agree <<<"$SUMMARY")
override=$((clear_joined - agree))
label_n=$(jq -r .label_n <<<"$SUMMARY")
label_agree=$(jq -r .label_agree <<<"$SUMMARY")
pop=$(jq -r .pop <<<"$SUMMARY")

{
  printf 'dispatch-resolve-score:\n'
  printf '  resolve_log: %s records=%s\n' "$RESOLVE_LOG" "$resolve_records"
  printf '  spawns_log: %s records=%s\n' "$SPAWNS_LOG" "$spawn_records"
  printf '  coverage: %s/%s = %s\n' "$covered_tasks" "$spawned_tasks" "$(fmt_frac "$covered_tasks" "$spawned_tasks")"
  printf '  clear_joined: %s\n' "$clear_joined"
  printf '  profile_agreement: %s/%s = %s\n' "$agree" "$clear_joined" "$(fmt_frac "$agree" "$clear_joined")"
  printf '  override_rate: %s/%s = %s\n' "$override" "$clear_joined" "$(fmt_frac "$override" "$clear_joined")"
  if [ -n "$LABELS" ]; then
    printf '  rule_agreement: %s/%s = %s\n' "$label_agree" "$label_n" "$(fmt_frac "$label_agree" "$label_n")"
  fi
  printf '  floors:\n'
  jq -c '.floors[]' <<<"$SUMMARY" | while IFS= read -r row; do
    f=$(jq -r .floor <<<"$row")
    wc=$(jq -r .wc <<<"$row")
    prec_n=$(jq -r .prec_n <<<"$row")
    prec_agree=$(jq -r .prec_agree <<<"$row")
    lab_n=$(jq -r .lab_n <<<"$row")
    lab_agree=$(jq -r .lab_agree <<<"$row")
    mark=''
    if [ "$(jq -r .live <<<"$row")" = true ]; then mark=' *'; fi
    if [ "$prec_n" = null ]; then
      spawn_col='n/a'
    else
      spawn_col=$(printf '%s (%s/%s)' "$(fmt_frac "$prec_agree" "$prec_n")" "$prec_agree" "$prec_n")
    fi
    line=$(printf '    floor=%s%s clear_frac=%s (%s/%s) precision_vs_spawn=%s' \
      "$(fmt_floor "$f")" "$mark" "$(fmt_frac "$wc" "$pop")" "$wc" "$pop" "$spawn_col")
    if [ -n "$LABELS" ]; then
      line="$line$(printf ' precision_vs_label=%s (%s/%s)' "$(fmt_frac "$lab_agree" "$lab_n")" "$lab_agree" "$lab_n")"
    fi
    printf '%s\n' "$line"
  done
}
exit 0
