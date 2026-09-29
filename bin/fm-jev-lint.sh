#!/usr/bin/env bash
# fm-jev-lint.sh - advisory worker self-check: frozen Jev questions over the
# worker's own diff, run after implementation and before no-mistakes validation.
#
# Usage:
#   fm-jev-lint.sh check [--diff-file <file>] [--record <path>]
#   fm-jev-lint.sh resolve --id <finding-id> --verdict fixed|dismissed [--reason <text>] [--record <path>]
#   fm-jev-lint.sh score [--record <path>]
#
# What check does: diffs HEAD against the merge-base of HEAD with origin/main,
#   else main, with -U8 (committed work only), extracts diff-scoped
#   subjects deterministically (changed functions with their leading comments
#   as R1, touched test blocks as R2, added prose enumerations with their
#   surrounding diff context as R3, timeout or budget declarations in the
#   diff as R4), sends one Jev noul request per subject in parallel through
#   bin/fm-branch-shadow-jev.sh, prints one
#   line per flagged finding with its id, and appends one JSON line per subject
#   to the record. Several bounds keep the cost fixed and are silent when they
#   bite: at most MAX_SUBJECTS (30) subjects per run, taken in diff order, so a
#   larger diff has its later subjects dropped unchecked; an R3 bullet run
#   contributes at most its first 10 items to the claim; an R1 subject's
#   evidence stops after 8 body lines and an R2 subject's after 12; and every
#   claim is cut at CLAIM_CAP (500) bytes and every evidence at EVIDENCE_CAP
#   (1500) bytes, mid-token if need be, before the subject is sent and
#   recorded. What resolve does: appends one outcome line recording how a
#   finding was handled. What score does: reads the record and prints per-rule
#   cost, latency, and fixed-versus-dismissed rates. docs/configuration.md
#   "Jev self-check record" owns the operator contract; this header owns the
#   exact flags, subject shapes, and record fields.
#
# Frozen set: bin/fm-jev-lint-rules.json carries each rule's exact question,
#   cutoff, and enabled flag, copied verbatim from the Tier-1 pilot's frozen
#   artifacts. R3 carries the reworded v2 question only (revalidated at 0.875
#   precision and recall); the v1 wording is never used. A rule whose live
#   fixed-over-resolved rate falls below 0.80 over its first 20 runs is removed
#   by flipping its enabled flag to false, a one-line data change; score flags
#   the candidate but never edits the set.
#
# Policy in code: findings are candidates the worker fixes or dismisses with a
#   reason. They never gate, skip, prune, or approve anything: check always
#   exits 0 once it runs, and a finding never changes what validation does.
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get, the same
#   accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh). The environment wins.
#   Absent in both: nothing on stdout or stderr, exit 0, no network call,
#   nothing recorded. The gate is a presence check only: the key
#   value is never read into this script. Every request goes through
#   bin/fm-branch-shadow-jev.sh, which owns the endpoint and the key
#   discipline; an unavailable answer records a null probability and raises no
#   finding.
#
# Data boundary: subjects are drawn from the worker's own diff only, and paths
#   any of whose components look secrets-like are never read or sent, matched
#   case-insensitively: .env files,
#   *secret*, *credential*, *passwd*, *.pem, *.p12, id_rsa*, id_ed25519*, and
#   *.key. The `excluded` expression in extract_subjects' flush_file is the
#   single owner of that list. Path exclusion is not enough on its own, so
#   every extracted subject also passes subject_has_secret before check
#   dispatches it: a subject whose claim or evidence carries a private-key
#   block, a token-shaped value, or an assignment to a key, token, secret,
#   password or passwd name is dropped, never sent and never recorded as a
#   subject.
#
# Record: one JSON object per line in $FM_HOME/data/jev-lint.jsonl, or the
#   --record path when given. A check line carries ts
#   (UTC ISO 8601), run_id, kind "check", id "<run_id>-<seq>", rule, cutoff,
#   file, claim and evidence (the exact subject text sent), probability (or
#   null on transport failure), flagged, input_tokens, cost_usd, latency_ms,
#   and model. An outcome line carries ts, run_id, kind "outcome", id (the
#   finding it answers), rule, verdict "fixed" or "dismissed", and reason.
#   A run that dropped secret-like subjects appends one line carrying ts,
#   run_id, kind "dropped", and count - the count alone, never the subject.
#   Only data/ itself is created when absent; a failed append prints one
#   stderr line and never changes the exit code.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-$FM_ROOT}"
RULES_FILE="${FM_JEV_LINT_RULES:-$SCRIPT_DIR/fm-jev-lint-rules.json}"
RECORD_DEFAULT="$FM_HOME/data/jev-lint.jsonl"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

JEV_SHIM="$SCRIPT_DIR/fm-branch-shadow-jev.sh"
export TS_TIMEOUT="${TS_TIMEOUT:-30}"
MAX_SUBJECTS=30
CLAIM_CAP=500
EVIDENCE_CAP=1500

die() { printf 'jev-lint: error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# The record's parent directory alone is created when absent; a failed append
# prints one stderr line and never changes the outcome.
record_append() {  # <record-path> <json-line>
  case $1 in */*) mkdir -p "${1%/*}" 2>/dev/null || true ;; esac
  { printf '%s\n' "$2" >> "$1"; } 2>/dev/null || \
    printf 'jev-lint: record unwritable: %s\n' "$1" >&2
  return 0
}

# Ends every still-running subject job so an interrupted run stops where it is
# instead of printing findings no record line can answer.
stop_jobs() {
  local pids
  pids=$(jobs -p)
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086  # deliberate split: one kill for every job id
  kill $pids 2>/dev/null || true
  wait 2>/dev/null || true
  return 0
}

# Appends every finished job's check line to the record. Runs once on the
# normal path and from the interrupt trap, so a killed run keeps the lines its
# completed jobs already produced.
flush_record_lines() {  # <workdir> <record-path>
  local line_file
  for line_file in "$1"/line-*; do
    [ -e "$line_file" ] || break
    record_append "$2" "$(cat "$line_file")"
    rm -f "$line_file"
  done
  return 0
}

# Opt-in gate shared by check (resolve and score are local-only and never need
# the key). Returns 1 without printing anything when the key is absent, else 0.
require_key() {
  [ -n "${TYPESAFE_API_KEY:-}" ] && return 0
  fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env" | grep -q . && return 0
  return 1
}

# Content boundary for the subjects the path filter cannot catch: credential
# material in an ordinary-named file. True when the text carries a private-key
# block, a token-shaped value, or an assignment to a secrets-like name.
subject_has_secret() {  # <text>
  printf '%s\n' "$1" | grep -qE \
    '(-----BEGIN[A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]|github_pat_[A-Za-z0-9]|xox[baprs]-[A-Za-z0-9]|(^|[^A-Za-z0-9_])sk-[A-Za-z0-9]|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{20,}|eyJ[A-Za-z0-9_-]{10,})' \
    && return 0
  printf '%s\n' "$1" | grep -qiE \
    '(^|[^A-Za-z0-9_])[A-Za-z0-9_]*(key|token|secret|password|passwd)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]]' \
    && return 0
  return 1
}

enabled_rules() {
  jq -r '.rules | to_entries[] | select(.value.enabled) | .key' "$RULES_FILE"
}

# --- subject extraction -------------------------------------------------------
# Reads a unified diff with file headers on stdin, writes one TSV line per
# subject on stdout: rule, file, claim, evidence (tabs and newlines flattened,
# capped). Deterministic: same diff bytes always yield the same subjects.
extract_subjects() {
  LC_ALL=C awk -v claim_cap="$CLAIM_CAP" -v ev_cap="$EVIDENCE_CAP" '
  function cap(s, n) { if (length(s) > n) s = substr(s, 1, n); return s }
  function flat(s) { gsub(/\t/, " ", s); gsub(/\n/, " ", s); gsub(/\r/, "", s); return s }
  function is_comment(l) { return (l ~ /^[[:space:]]*(#|\/\/|\*|;|")/) }
  function is_banner(l) { return (l ~ /^[[:space:]]*(#|\/\/|;|\*)+[[:space:]]*[-=]{2,}/) }
  function is_func(l) {
    if (l ~ /^[[:space:]]*(\}[[:space:]]*)?(else[[:space:]]+)?(if|elif|for|foreach|while|until|do|switch|case|catch|except|with)[[:space:]]*\(/) return 0
    return (l ~ /^[[:space:]]*(function[[:space:]]+[A-Za-z_][A-Za-z0-9_:.-]*|def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|func[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)[[:space:]]*\{|[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\([^)]*\)[[:space:]]*\{)/)
  }
  function is_test_name(l) {
    return (l ~ /(it|test|it_each|itBehavesLike)[[:space:]]*\(?[[:space:]]*["'"'"'`]/ || l ~ /^[[:space:]]*(def[[:space:]]+test_[A-Za-z0-9_]+|func[[:space:]]+Test[A-Za-z0-9_]*)/)
  }
  function is_budget(l) {
    bl = tolower(l); return (bl ~ /(timeout|budget|deadline|ttl|expir)/ && l ~ /[0-9]/)
  }
  function is_list_item(l) {
    return (l ~ /^[[:space:]]*([-*+][[:space:]]|[0-9]+\.[[:space:]])/)
  }
  function is_enum_line(l,   c, q) {
    if (is_list_item(l)) return 0
    c = gsub(/,/, ",", l); q = gsub(/`/, "`", l) + gsub(/"/, "\"", l)
    return (c >= 2 && q >= 4)
  }
  function r3_context(from, to, skip_from, skip_to,   k, ev, lo, hi) {
    lo = skip_from; while (lo > 1 && lo > from && !bound[lo]) lo--
    hi = skip_to - 1; while (hi < n && hi < to && !bound[hi + 1]) hi++
    ev = ""
    for (k = lo; k <= hi; k++) {
      if (k >= skip_from && k < skip_to) continue
      ev = ev (ev == "" ? "" : " ") lines[k]
    }
    return ev
  }
  function is_test_file(f) { return (f ~ /[Tt]est|[Ss]pec/) }
  function unquote(p,   out, i, c, d, n, j) {
    if (p !~ /^"/) return p
    p = substr(p, 2, length(p) - 2)
    out = ""
    for (i = 1; i <= length(p); i++) {
      c = substr(p, i, 1)
      if (c != "\\") { out = out c; continue }
      c = substr(p, ++i, 1)
      if (c == "t") out = out "\t"
      else if (c == "n") out = out "\n"
      else if (c == "r") out = out "\r"
      else if (c >= "0" && c <= "7") {
        n = 0
        for (j = 0; j < 3; j++) {
          d = substr(p, i, 1)
          if (d < "0" || d > "7") break
          n = n * 8 + (d + 0); i++
        }
        i--
        out = out sprintf("%c", n)
      }
      else out = out c
    }
    return out
  }
  function emit(rule, file, claim, ev) {
    file = flat(file)
    claim = cap(flat(claim), claim_cap); ev = cap(flat(ev), ev_cap)
    if (claim == "" || ev == "") return
    printf "%s\t%s\t%s\t%s\n", rule, file, claim, ev
  }
  /^diff --git / { flush_file(); file = ""; n = 0; in_hunk = 0; delete bound; next }
  !in_hunk && /^\+\+\+ / {
    file = unquote(substr($0, 5))
    sub(/^b\//, "", file)
    next
  }
  !in_hunk && /^--- / { next }
  /^\\/ { next }
  /^@@ / { in_hunk = 1; bound[n + 1] = 1; next }
  in_hunk && /^ / { lines[++n] = substr($0, 2); kinds[n] = " "; next }
  in_hunk && /^\+/ { lines[++n] = substr($0, 2); kinds[n] = "+"; next }
  in_hunk && /^-/ { next }
  { in_hunk = 0; next }
  function flush_file(  i, j, k, claim, ev, body, added, lf) {
    if (file == "" || n == 0) { n = 0; return }
    lf = tolower(file)
    excluded = (lf ~ /(^|\/)\.env/ || lf ~ /secret/ || lf ~ /credential/ || lf ~ /passwd/ || lf ~ /\.pem$/ || lf ~ /\.p12$/ || lf ~ /(^|\/)id_rsa/ || lf ~ /(^|\/)id_ed25519/ || lf ~ /\.key$/)
    if (!excluded) {
      for (i = 1; i <= n; i++) {
        if (!is_func(lines[i])) continue
        added = (kinds[i] == "+")
        for (k = i + 1; k <= n && !bound[k] && !is_func(lines[k]); k++) if (kinds[k] == "+") added = 1
        if (!added) continue
        claim = ""; j = i - 1
        while (j >= 1 && !bound[j + 1] && is_comment(lines[j]) && !is_banner(lines[j])) { claim = lines[j] (claim == "" ? "" : " " claim); j-- }
        if (claim == "") continue
        ev = lines[i]; body = 0
        for (k = i + 1; k <= n && body < 8; k++) {
          if (bound[k]) break
          if (kinds[k] != "+") continue
          if (is_func(lines[k])) break
          ev = ev " " lines[k]; body++
        }
        emit("r1", file, claim, ev)
      }
      if (is_test_file(file)) {
        for (i = 1; i <= n; i++) {
          if (kinds[i] != "+") continue
          if (!is_test_name(lines[i])) continue
          claim = lines[i]; ev = ""; body = 0
          for (k = i + 1; k <= n && body < 12; k++) {
            if (bound[k]) break
            if (kinds[k] == "+" && is_test_name(lines[k])) break
            ev = ev (ev == "" ? "" : " ") lines[k]; body++
          }
          emit("r2", file, claim, ev)
        }
      }
      for (i = 1; i <= n; i++) {
        if (kinds[i] != "+") continue
        if (!is_budget(lines[i])) continue
        claim = lines[i]; ev = ""
        lo = i; while (lo > 1 && lo > i - 5 && !bound[lo]) lo--
        hi = i; while (hi < n && hi < i + 5 && !bound[hi + 1]) hi++
        for (k = lo; k <= hi; k++) ev = ev (ev == "" ? "" : " ") lines[k]
        emit("r4", file, claim, ev)
      }
      for (i = 1; i <= n; i++) {
        if (kinds[i] != "+") continue
        if (is_list_item(lines[i])) {
          if (i > 1 && !bound[i] && kinds[i-1] == "+" && is_list_item(lines[i-1])) continue
          enum = lines[i]; cnt = 1
          for (k = i + 1; k <= n && !bound[k] && kinds[k] == "+" && is_list_item(lines[k]) && cnt < 10; k++) {
            enum = enum " " lines[k]; cnt++
          }
          if (cnt < 2) continue
          emit("r3", file, enum, r3_context(i - 5, i + cnt + 4, i, i + cnt))
        } else if (is_enum_line(lines[i])) {
          emit("r3", file, lines[i], r3_context(i - 5, i + 5, i, i + 1))
        }
      }
    }
    file = ""; n = 0; delete bound
  }
  END { flush_file() }
  '
}

# --- check --------------------------------------------------------------------
cmd_check() {
  local diff_file='' record="$RECORD_DEFAULT" jobs=8
  while [ $# -gt 0 ]; do
    case "$1" in
      --diff-file) [ $# -ge 2 ] || die "--diff-file needs a value"; diff_file=$2; shift 2 ;;
      --record) [ $# -ge 2 ] || die "--record needs a value"; record=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag $1" ;;
    esac
  done
  require_key || exit 0
  command -v jq >/dev/null 2>&1 || die "jq required"
  [ -r "$RULES_FILE" ] || die "rules file not readable: $RULES_FILE"
  local model rate
  model=$(jq -r '.model' "$RULES_FILE")
  rate=$(jq -r '.rate_usd_per_m_input_tokens' "$RULES_FILE")
  local diff_text
  if [ -n "$diff_file" ]; then
    [ -r "$diff_file" ] || die "diff file not readable: $diff_file"
    diff_text=$(cat "$diff_file")
  else
    local base
    if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      base=$(git merge-base HEAD origin/main 2>/dev/null) || die "no merge-base with origin/main (pass --diff-file)"
    elif git rev-parse --verify --quiet main >/dev/null 2>&1; then
      base=$(git merge-base HEAD main 2>/dev/null) || die "no merge-base with main (pass --diff-file)"
    else
      die "no base ref found (pass --diff-file)"
    fi
    diff_text=$(git diff -U8 "$base"...HEAD -- . 2>/dev/null) || die "git diff failed"
  fi
  [ -n "$diff_text" ] || { echo "jev-lint: no changes, nothing to check" >&2; exit 0; }
  local subjects
  subjects=$(printf '%s\n' "$diff_text" | extract_subjects)
  [ -n "$subjects" ] || { echo "jev-lint: no subjects in diff, nothing to check" >&2; exit 0; }
  local run_id ts workdir
  run_id="$(date +%s)-$$"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  workdir=$(mktemp -d) || die "mktemp failed"
  trap 'flush_record_lines "$workdir" "$record"; rm -rf "$workdir"' EXIT
  trap 'stop_jobs; flush_record_lines "$workdir" "$record"; rm -rf "$workdir"; exit 0' INT TERM
  local seq=0 live=0 checked=0 dropped=0
  while IFS=$'\t' read -r rule file claim ev; do
    if subject_has_secret "$claim $ev"; then dropped=$((dropped + 1)); continue; fi
    seq=$((seq + 1))
    [ "$seq" -gt "$MAX_SUBJECTS" ] && break
    enabled_rules | grep -qx "$rule" || continue
    jev_lint_one "$workdir" "$seq" "$run_id" "$ts" "$rule" "$file" "$claim" "$ev" "$model" "$rate" &
    checked=$((checked + 1))
    live=$((live + 1))
    if [ "$live" -ge "$jobs" ]; then wait -n; live=$((live - 1)); fi
  done <<< "$subjects"
  wait
  local flags
  flush_record_lines "$workdir" "$record"
  flags=$(grep -c . "$workdir/count" 2>/dev/null || echo 0)
  trap - EXIT
  rm -rf "$workdir"
  if [ "$dropped" -gt 0 ]; then
    record_append "$record" "$(jq -cn --arg ts "$ts" --arg run "$run_id" --argjson n "$dropped" \
      '{ts: $ts, run_id: $run, kind: "dropped", count: $n}')"
  fi
  echo "jev-lint: run $run_id: $checked subject(s) checked, $dropped dropped as secret-like, $flags finding(s) above (if any) are advisory" >&2
  return 0
}

# One Jev request for one subject: POSTs the frozen question with the subject
# as state, prints a finding line when p >= cutoff, and publishes its one check
# line in the workdir for cmd_check to append once the run finishes or is
# interrupted.
# The key never enters this script: bin/fm-branch-shadow-jev.sh owns the
# transport and the key discipline, and an unavailable answer records a null
# probability that can never raise a finding.
jev_lint_one() {  # <workdir> <seq> <run_id> <ts> <rule> <file> <claim> <ev> <model> <rate>
  local workdir=$1 seq=$2 run_id=$3 ts=$4 rule=$5 file=$6 claim=$7 ev=$8 model=$9 rate=${10}
  local id cutoff question crit_t crit_f prob tokens lat_ms cost resp_file req_file
  id="$run_id-$seq"
  cutoff=$(jq -r --arg r "$rule" '.rules[$r].cutoff' "$RULES_FILE")
  question=$(jq -r --arg r "$rule" '.rules[$r].question' "$RULES_FILE")
  crit_t=$(jq -r --arg r "$rule" '.rules[$r].criteria_true' "$RULES_FILE")
  crit_f=$(jq -r --arg r "$rule" '.rules[$r].criteria_false' "$RULES_FILE")
  resp_file="$workdir/resp-$seq"
  req_file="$workdir/req-$seq"
  prob=null tokens=0 lat_ms=1
  jq -n --arg model "$model" --arg claim "$claim" --arg ev "$ev" \
    --arg q "$question" --arg t "$crit_t" --arg f "$crit_f" '
    {model: $model, state: {claim: $claim, evidence: $ev},
     questions: {violated: {type: "noul", instructions: $q,
       criteria: {"true": $t, "false": $f}}}}' > "$req_file" || return 0
  local t0 t1
  t0=$(date +%s%3N 2>/dev/null || date +%s)
  "$JEV_SHIM" < "$req_file" > "$resp_file" 2>/dev/null || true
  t1=$(date +%s%3N 2>/dev/null || date +%s)
  if [[ "$t0" == *N || "$t1" == *N ]]; then lat_ms=0
  elif [ "${#t0}" -le 10 ]; then lat_ms=$(( (t1 - t0) * 1000 )); else lat_ms=$((t1 - t0)); fi
  if jq -e '.ok' "$resp_file" >/dev/null 2>&1; then
    prob=$(jq -r '.answers.violated.noul | if type == "number" then . else "null" end' "$resp_file" 2>/dev/null) || prob=null
    tokens=$(jq -r '.usage.input_tokens | if type == "number" then . else 0 end' "$resp_file" 2>/dev/null) || tokens=0
  fi
  local flagged=false
  if [ "$prob" != "null" ] && awk -v p="$prob" -v c="$cutoff" 'BEGIN{exit !(p >= c)}'; then
    flagged=true
  fi
  cost=$(awk -v t="$tokens" -v r="$rate" 'BEGIN{printf "%.8f", t * r / 1000000}')
  local line
  line=$(jq -cn --arg ts "$ts" --arg run "$run_id" --arg id "$id" --arg rule "$rule" \
    --argjson cutoff "$cutoff" --arg file "$file" --arg claim "$claim" --arg ev "$ev" \
    --argjson prob "$prob" --argjson flagged "$flagged" --argjson tok "$tokens" \
    --argjson cost "$cost" --argjson lat "$lat_ms" --arg model "$model" '
    {ts: $ts, run_id: $run, kind: "check", id: $id, rule: $rule, cutoff: $cutoff,
     file: $file, claim: $claim, evidence: $ev, probability: $prob, flagged: $flagged,
     input_tokens: $tok, cost_usd: $cost, latency_ms: $lat, model: $model}')
  printf '%s\n' "$line" > "$workdir/tmp-$seq" && mv "$workdir/tmp-$seq" "$workdir/line-$seq"
  if [ "$flagged" = true ]; then
    printf 'jev-lint finding %s [%s %s p=%s cutoff=%s]: %s\n' "$id" "$rule" "$file" "$prob" "$cutoff" "$claim"
  fi
  if [ "$flagged" = true ]; then
    printf 'x\n' >> "$workdir/count" || true
  fi
  return 0
}

# --- resolve ------------------------------------------------------------------
cmd_resolve() {
  local id='' verdict='' reason='' record="$RECORD_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) [ $# -ge 2 ] || die "--id needs a value"; id=$2; shift 2 ;;
      --verdict) [ $# -ge 2 ] || die "--verdict needs a value"; verdict=$2; shift 2 ;;
      --reason) [ $# -ge 2 ] || die "--reason needs a value"; reason=$2; shift 2 ;;
      --record) [ $# -ge 2 ] || die "--record needs a value"; record=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag $1" ;;
    esac
  done
  [ -n "$id" ] || die "--id required"
  case "$verdict" in
    fixed|dismissed) ;;
    *) die "--verdict must be fixed or dismissed" ;;
  esac
  command -v jq >/dev/null 2>&1 || die "jq required"
  local rule run_id
  run_id=${id%-*}
  [ -r "$record" ] || die "no record at $record"
  rule=$(jq -rs --arg id "$id" '
    if any(.[]; .kind == "outcome" and .id == $id) then "duplicate"
    else ([.[] | select(.kind == "check" and .id == $id and .flagged)] | .[0].rule // "missing") end' \
    "$record" 2>/dev/null) || rule=missing
  case "$rule" in
    duplicate) die "id $id is already resolved in $record" ;;
    missing|'') die "no flagged finding with id $id in $record" ;;
  esac
  local line
  line=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg run "$run_id" \
    --arg id "$id" --arg rule "$rule" --arg v "$verdict" --arg reason "$reason" '
    {ts: $ts, run_id: $run, kind: "outcome", id: $id, rule: $rule, verdict: $v, reason: $reason}')
  record_append "$record" "$line"
  printf 'jev-lint: %s recorded as %s\n' "$id" "$verdict"
  return 0
}

# --- score --------------------------------------------------------------------
cmd_score() {
  local record="$RECORD_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --record) [ $# -ge 2 ] || die "--record needs a value"; record=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag $1" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "jq required"
  [ -r "$record" ] || { printf 'jev-lint score: no record at %s\n' "$record"; exit 0; }
  jq -rs '
    ([.[] | select(.kind == "check")] | length) as $checks |
    ([.[] | select(.kind == "check" and .flagged)] | length) as $flags |
    ([.[] | select(.kind == "check") | .run_id] | unique | length) as $runs |
    ([.[] | select(.kind == "check") | .input_tokens] | add // 0) as $toks |
    ([.[] | select(.kind == "check") | .cost_usd] | add // 0) as $cost |
    ([.[] | select(.kind == "check") | .latency_ms] | (add // 0) / (length | if . == 0 then 1 else . end)) as $lat |
    ([.[] | select(.kind == "outcome" and .verdict == "fixed")] | length) as $fixed |
    ([.[] | select(.kind == "outcome" and .verdict == "dismissed")] | length) as $dismissed |
    "jev-lint score: runs=\($runs) checks=\($checks) flagged=\($flags) fixed=\($fixed) dismissed=\($dismissed) open=\($flags - $fixed - $dismissed) cost_usd=\($cost) cost_per_run=\(if $runs == 0 then 0 else $cost / $runs end) mean_latency_ms=\($lat | floor) input_tokens=\($toks)",
    (([.[] | select(.kind == "outcome")] | group_by(.rule) | map({
      key: .[0].rule,
      value: {fixed: ([.[] | select(.verdict == "fixed")] | length),
              dismissed: ([.[] | select(.verdict == "dismissed")] | length)}
    }) | from_entries) as $out |
    ([.[] | select(.kind == "check")] | group_by(.rule) | map(
      .[0].rule as $r |
      (map(.run_id) | unique | length) as $rr |
      (length) as $cc |
      ([.[] | select(.flagged)] | length) as $ff |
      ([.[] | .cost_usd] | add // 0) as $rc |
      ([.[] | .latency_ms] | (add // 0) / $cc) as $rl |
      ($out[$r].fixed // 0) as $rfix |
      ($out[$r].dismissed // 0) as $rdis |
      "  rule \($r): runs=\($rr) checks=\($cc) flagged=\($ff) cost_usd=\($rc) cost_per_run=\(if $rr == 0 then 0 else $rc / $rr end) mean_latency_ms=\($rl | floor) fixed=\($rfix) dismissed=\($rdis) fixed_rate=\(if $rfix + $rdis == 0 then "n/a" else $rfix / ($rfix + $rdis) end)"
    ))[])' "$record"
  jq -rs --slurpfile rules "$RULES_FILE" '
    ([.[] | select(.kind == "check")] | group_by(.rule) | map({
      key: .[0].rule,
      value: {runs: ([.[] | .run_id] | unique | length)}
    }) | from_entries) as $by_rule |
    ([.[] | select(.kind == "outcome")] | group_by(.rule) | map({
      key: .[0].rule,
      value: {fixed: ([.[] | select(.verdict == "fixed")] | length),
              dismissed: ([.[] | select(.verdict == "dismissed")] | length)}
    }) | from_entries) as $out |
    ($rules[0].rules | to_entries[] |
      .key as $r | .value.enabled as $en |
      ($by_rule[$r].runs // 0) as $runs |
      (($out[$r].fixed // 0) + ($out[$r].dismissed // 0)) as $res |
      (if $res == 0 then 1 else ($out[$r].fixed // 0) / $res end) as $prec |
      if $en and $runs >= 20 and $prec < 0.80
      then "  DROP-CANDIDATE rule \($r): \($runs) runs, fixed-over-resolved=\($prec) below 0.80 - flip enabled to false in fm-jev-lint-rules.json"
      else empty end)' "$record"
  return 0
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
cmd=$1
shift
case "$cmd" in
  check) cmd_check "$@" ;;
  resolve) cmd_resolve "$@" ;;
  score) cmd_score "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) die "unknown command $cmd (check, resolve, score)" ;;
esac
