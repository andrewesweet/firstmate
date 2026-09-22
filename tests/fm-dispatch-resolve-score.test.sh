#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-resolve-score.sh.
#
# Drives the public argv and environment interface with synthetic resolver and
# spawn logs plus a labels file. No network, no key, no resolver run: every
# number in the expected report below is hand-computed from the fixture, so the
# full-output assertions pin coverage, clear-only profile agreement, override
# rate, rule agreement, and the precision-versus-abstention curve exactly.
# The t1 rows prove the join picks the latest resolver record before the spawn
# (r2, not r1), and the t6 rows prove a spawn before any resolver record stays
# uncovered.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-dispatch-resolve-score.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve-score)
RESOLVE_LOG="$TMP_ROOT/resolve.jsonl"
SPAWNS_LOG="$TMP_ROOT/spawns.jsonl"
LABELS="$TMP_ROOT/labels.txt"

# t1 is resolved twice (r1 then r2) and spawned once after r2, on r2's profile.
# t2 is spawned on an ambiguous call. t3 is spawned on a different profile than
# the clear pick (an override). t5 is spawned with no resolver record. t6 is
# spawned before its only resolver record, so it stays uncovered. t4 escalated
# and the task-less record still carry a numeric confidence, so the floor curve
# counts all seven records.
cat > "$RESOLVE_LOG" <<'JSON'
{"ts":"2030-01-01T00:00:01Z","task":"t1","status":"clear","confidence":0.92,"rule":"rule_1 (Fast work.)","profile":"--harness 'claude' --model 'sonnet' --effort 'high'","selected_option":"Fast work."}
{"ts":"2030-01-01T00:00:02Z","task":"t1","status":"clear","confidence":0.81,"rule":"rule_2 (Slow work.)","profile":"--harness 'codex' --model 'gpt-5'","selected_option":"Slow work."}
{"ts":"2030-01-01T00:00:03Z","task":"t2","status":"ambiguous","confidence":0.41,"rule":"rule_1 (Fast work.)","profile":null,"selected_option":"Fast work."}
{"ts":"2030-01-01T00:00:04Z","task":"t3","status":"clear","confidence":0.95,"rule":"rule_1 (Fast work.)","profile":"--harness 'claude' --model 'sonnet' --effort 'high'","selected_option":"Fast work."}
{"ts":"2030-01-01T00:00:05Z","task":"t4","status":"escalate","confidence":0.99,"rule":"rule_3 (Hard work.)","profile":null,"selected_option":"Hard work."}
{"ts":"2030-01-01T00:00:06Z","task":null,"status":"clear","confidence":0.7,"rule":"rule_1 (Fast work.)","profile":"--harness 'pi'","selected_option":"Fast work."}
{"ts":"2030-01-01T00:00:09Z","task":"t6","status":"clear","confidence":0.88,"rule":"rule_1 (Fast work.)","profile":"--harness 'claude'","selected_option":"Fast work."}
JSON
cat > "$SPAWNS_LOG" <<'JSON'
{"ts":"2030-01-01T00:00:07Z","task":"t1","kind":"ship","harness":"codex","model":"gpt-5","effort":"default"}
{"ts":"2030-01-01T00:00:07Z","task":"t2","kind":"scout","harness":"claude","model":"sonnet","effort":"high"}
{"ts":"2030-01-01T00:00:07Z","task":"t3","kind":"ship","harness":"claude","model":"opus","effort":"default"}
{"ts":"2030-01-01T00:00:07Z","task":"t5","kind":"ship","harness":"pi","model":"default","effort":"default"}
{"ts":"2030-01-01T00:00:08Z","task":"t6","kind":"ship","harness":"claude","model":"default","effort":"default"}
JSON
printf 't1\tSlow work.\nt3\tSlow work.\n' > "$LABELS"

run() {
  local __out=$1 __code=$2
  shift 2
  local _out _code
  _out=$(FM_DISPATCH_RESOLVE_LOG="$RESOLVE_LOG" FM_DISPATCH_SPAWNS_LOG="$SPAWNS_LOG" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__out" '%s' "$_out"
  printf -v "$__code" '%s' "$_code"
}

code='' out=''

# --- full report with labels: every number asserted exactly ------------------
run out code --labels "$LABELS"
expect_code 0 "$code" "scorer exits 0"
expected=$(cat <<EOF
dispatch-resolve-score:
  resolve_log: $RESOLVE_LOG records=7
  spawns_log: $SPAWNS_LOG records=5
  coverage: 3/5 = 0.6000
  clear_joined: 2
  profile_agreement: 1/2 = 0.5000
  override_rate: 1/2 = 0.5000
  rule_agreement: 1/2 = 0.5000
  floors:
    floor=0.3 clear_frac=1.0000 (7/7) precision_vs_spawn=n/a precision_vs_label=0.3333 (1/3)
    floor=0.4 clear_frac=1.0000 (7/7) precision_vs_spawn=n/a precision_vs_label=0.3333 (1/3)
    floor=0.5 clear_frac=0.8571 (6/7) precision_vs_spawn=n/a precision_vs_label=0.3333 (1/3)
    floor=0.6 * clear_frac=0.8571 (6/7) precision_vs_spawn=0.5000 (1/2) precision_vs_label=0.3333 (1/3)
    floor=0.7 clear_frac=0.8571 (6/7) precision_vs_spawn=0.5000 (1/2) precision_vs_label=0.3333 (1/3)
    floor=0.8 clear_frac=0.7143 (5/7) precision_vs_spawn=0.5000 (1/2) precision_vs_label=0.3333 (1/3)
    floor=0.9 clear_frac=0.4286 (3/7) precision_vs_spawn=0.0000 (0/1) precision_vs_label=0.0000 (0/2)
EOF
)
assert_equals "$expected" "$out" "the full labeled report matches hand-computed numbers"
# t1 agrees only because the join picked r2 (codex/gpt-5) over r1
# (claude/sonnet/high): joining r1 would read 0/2, not 1/2.
assert_contains "$out" '  profile_agreement: 1/2 = 0.5000' "the join picks the latest resolver record before each spawn"
# t1's label names r2's when text and agrees; t3's label names "Slow work."
# while the pick was "Fast work.", so rule agreement reads 1/2.
assert_contains "$out" '  rule_agreement: 1/2 = 0.5000' "rule agreement judges the pick against the adjudicated label"
# Below the live floor the label precision judges every labelled record clear
# at that floor (r1, r2, t3: 1/3), while spawn precision has no evidence.
assert_contains "$out" '    floor=0.3 clear_frac=1.0000 (7/7) precision_vs_spawn=n/a precision_vs_label=0.3333 (1/3)' "sub-floor rows judge labelled records and mark spawn precision n/a"
# t6's only resolver record lands after its spawn, and t5 has none: both stay
# uncovered, so coverage reads 3/5 rather than 5/5.
assert_contains "$out" '  coverage: 3/5 = 0.6000' "records after the spawn and tasks without records stay uncovered"
pass "labeled replay: coverage, clear-only agreements, override rate, and the floor curve"

# --- without labels: no label lines or columns --------------------------------
run out code
expect_code 0 "$code" "unlabeled scorer exits 0"
assert_not_contains "$out" 'rule_agreement' "unlabeled output carries no rule agreement"
assert_not_contains "$out" 'precision_vs_label' "unlabeled floor lines carry no label precision"
assert_contains "$out" '  coverage: 3/5 = 0.6000' "unlabeled coverage is unchanged"
assert_contains "$out" '    floor=0.6 * clear_frac=0.8571 (6/7) precision_vs_spawn=0.5000 (1/2)' "unlabeled floor line keeps spawn precision"
pass "unlabeled replay omits every label-derived metric"

# --- missing spawns log: coverage 0, not an error ------------------------------
_out=$(FM_DISPATCH_RESOLVE_LOG="$RESOLVE_LOG" FM_DISPATCH_SPAWNS_LOG="$TMP_ROOT/no-such-log.jsonl" "$TOOL" 2> "$TMP_ROOT/stderr")
code=$?
expect_code 0 "$code" "missing spawns log exits 0"
assert_contains "$_out" '  spawns_log: '"$TMP_ROOT"'/no-such-log.jsonl records=0' "missing spawns log reads as zero records"
assert_contains "$_out" '  coverage: 0/0 = n/a' "missing spawns log is coverage 0, not an error"
assert_contains "$_out" '  clear_joined: 0' "missing spawns log joins nothing"
assert_contains "$_out" '  profile_agreement: 0/0 = n/a' "empty joins print n/a, not zeros"
assert_contains "$_out" '    floor=0.6 * clear_frac=0.8571 (6/7) precision_vs_spawn=n/a (0/0)' "floors still score the resolve log with n/a precision"
pass "a missing spawns log is coverage 0, not an error"

# --- logs beyond one argv value's 128 KiB still score ---------------------------
# 400 records padded to ~600 bytes each (the size of a live resolver record with
# its probability vector, policy, and rules digest) make a log over 200 KiB.
BIG_LOG="$TMP_ROOT/big-resolve.jsonl"
pad=$(printf 'x%.0s' $(seq 1 560))
: > "$BIG_LOG"
for i in $(seq 1 400); do
  printf '{"ts":"2030-01-01T00:00:01Z","task":"big%s","status":"clear","confidence":0.9,"rule":"rule_1 (Fast work.)","profile":"--harness \u0027claude\u0027","selected_option":"Fast work.","probabilities":"%s"}\n' "$i" "$pad"
done >> "$BIG_LOG"
[ "$(wc -c < "$BIG_LOG")" -gt 131072 ] || fail "big log fixture must exceed 128 KiB"
_out=$(FM_DISPATCH_RESOLVE_LOG="$BIG_LOG" FM_DISPATCH_SPAWNS_LOG="$SPAWNS_LOG" "$TOOL" 2> "$TMP_ROOT/stderr")
expect_code 0 "$?" "a resolve log over 128 KiB scores: $(cat "$TMP_ROOT/stderr")"
assert_contains "$_out" '  resolve_log: '"$BIG_LOG"' records=400' "every record of the big log is read"
assert_contains "$_out" '    floor=0.9 clear_frac=1.0000 (400/400)' "the floor curve covers every big-log record"
pass "a log beyond one argv value still scores"

# --- unreadable inputs exit 2 ---------------------------------------------------
printf 'not json\n' > "$TMP_ROOT/bad.jsonl"
_out=$(FM_DISPATCH_RESOLVE_LOG="$TMP_ROOT/bad.jsonl" FM_DISPATCH_SPAWNS_LOG="$SPAWNS_LOG" "$TOOL" 2> "$TMP_ROOT/stderr")
expect_code 2 "$?" "malformed resolve log exits 2"
assert_contains "$(cat "$TMP_ROOT/stderr")" 'malformed resolve log' "malformed resolve log is named"
printf '{"ts":"yesterday","task":"t1","status":"clear","confidence":0.9}\n' > "$TMP_ROOT/bad-ts.jsonl"
_out=$(FM_DISPATCH_RESOLVE_LOG="$TMP_ROOT/bad-ts.jsonl" FM_DISPATCH_SPAWNS_LOG="$SPAWNS_LOG" "$TOOL" 2> "$TMP_ROOT/stderr")
expect_code 2 "$?" "bad timestamp exits 2"
printf 'no-tab-here\n' > "$TMP_ROOT/bad-labels.txt"
_out=$(FM_DISPATCH_RESOLVE_LOG="$RESOLVE_LOG" FM_DISPATCH_SPAWNS_LOG="$SPAWNS_LOG" "$TOOL" --labels "$TMP_ROOT/bad-labels.txt" 2> "$TMP_ROOT/stderr")
expect_code 2 "$?" "malformed labels file exits 2"
assert_contains "$(cat "$TMP_ROOT/stderr")" 'malformed labels file' "malformed labels file is named"
_out=$(FM_DISPATCH_RESOLVE_LOG="$RESOLVE_LOG" FM_DISPATCH_SPAWNS_LOG="$SPAWNS_LOG" "$TOOL" --labels "$TMP_ROOT/no-such-labels.txt" 2> "$TMP_ROOT/stderr")
expect_code 2 "$?" "unreadable labels file exits 2"
_out=$(FM_DISPATCH_RESOLVE_LOG="$RESOLVE_LOG" FM_DISPATCH_SPAWNS_LOG="$SPAWNS_LOG" "$TOOL" --bogus 2> "$TMP_ROOT/stderr")
expect_code 2 "$?" "unknown flag exits 2"
run out code --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'Usage:' "--help prints usage"
pass "unreadable inputs exit 2 with a named error"

printf '# all fm-dispatch-resolve-score tests passed\n'
