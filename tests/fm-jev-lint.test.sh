#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-lint.sh (advisory worker self-check).
#
# Drives the public argv interface with a fixture diff, a fakebin curl that
# answers the real call shim, and a scratch record. No network, no key on the
# wire: the fake curl refuses to answer unless a test hands it per-rule
# probabilities, so a request that escaped the suite's control can only be
# recorded as unavailable. What a subject was dispatched at all is asserted on
# the record instead - the secret-drop test requires zero check lines. The
# probabilities pin cutoff application exactly, and the scorer test
# hand-computes every number from a record fixture written to the documented
# record contract (docs/configuration.md "Jev self-check record").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-lint)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'CURL'
#!/usr/bin/env bash
# Answers a TypeSafe System One request the way the live endpoint would, picking
# the probability by the rule whose frozen question the request body carries.
if [ -z "${FM_FAKE_JEV_PROBS:-}" ]; then
  echo "fake curl must never run" >&2
  exit 42
fi
out=''
while [ $# -gt 0 ]; do
  case $1 in -o) out=$2; shift 2 ;; *) shift ;; esac
done
req=$(cat)
[ -n "${FM_FAKE_JEV_FAIL:-}" ] && exit 7
[ -n "${FM_FAKE_JEV_SLEEP:-}" ] && sleep "$FM_FAKE_JEV_SLEEP"
question=$(printf '%s' "$req" | jq -r '.questions.violated.instructions')
rule=$(jq -r --arg q "$question" '.rules | to_entries[] | select(.value.question == $q) | .key' "${FM_FAKE_JEV_RULES:?}")
prob=$(printf '%s' "${FM_FAKE_JEV_PROBS}" | jq -r --arg r "$rule" '.[$r] // empty')
[ -n "$prob" ] || { printf '404'; exit 0; }
if [ -n "${FM_FAKE_JEV_MALFORMED:-}" ]; then
  printf '{"model":"jev-1.13.0","answers":{"violated":{"noul":"high"}},"usage":{"input_tokens":"lots"}}' > "$out"
else
  jq -cn --argjson p "$prob" --argjson tok "${FM_FAKE_JEV_TOKENS:-100}" \
    '{model: "jev-1.13.0", answers: {violated: {noul: $p}}, usage: {input_tokens: $tok}}' > "$out"
fi
printf '200'
CURL
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"
RECORD="$TMP_ROOT/record.jsonl"
RULES="$ROOT/bin/fm-jev-lint-rules.json"
DIFF="$TMP_ROOT/subjects.diff"

cat > "$DIFF" <<'EOF'
diff --git a/src/thing.sh b/src/thing.sh
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ b/src/thing.sh
@@ -0,0 +1,8 @@
+# returns 0 on success
+fm_thing() {
+  rm -rf /tmp/x
+  return 1
+}
diff --git a/test/thing.test.sh b/test/thing.test.sh
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ b/test/thing.test.sh
@@ -0,0 +1,6 @@
+it "reports success", {
+  run_thing
+}
+FM_TIMEOUT=5
+sleep 60
diff --git a/.env b/.env
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ b/.env
@@ -0,0 +1 @@
+TYPESAFE_API_KEY=sekrit
diff --git a/deploy/secrets/values.sh b/deploy/secrets/values.sh
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ b/deploy/secrets/values.sh
@@ -0,0 +1,3 @@
+# returns the tenant list
+fm_tenants() { echo acme-globex-initech-hunter2 }
diff --git a/my secrets/key.sh b/my secrets/key.sh
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ b/my secrets/key.sh
@@ -0,0 +1,3 @@
+# returns the spaced tenant list
+fm_spaced() { echo spacedtenant42 }
diff --git a/Config/.ENV.sh b/Config/.ENV.sh
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ b/Config/.ENV.sh
@@ -0,0 +1,3 @@
+# returns the upper-case tenant list
+fm_upper() { echo uppertenant43 }
EOF

BIGDIFF="$TMP_ROOT/big.diff"
{
  esc=$(printf '\033%.0s' $(seq 1 1500))
  for i in 1 2 3 4 5 6 7 8; do
    printf 'diff --git a/src/big%s.sh b/src/big%s.sh\n' "$i" "$i"
    printf 'index 0000000..1111111 100644\n--- /dev/null\n+++ b/src/big%s.sh\n' "$i"
    printf '@@ -0,0 +1,3 @@\n'
    printf '+# returns the rendered board\n'
    printf '+fm_render%s() { printf %s; }\n' "$i" "'$esc'"
  done
} > "$BIGDIFF"

MANYDIFF="$TMP_ROOT/many.diff"
{
  for i in $(seq 1 16); do
    printf 'diff --git a/src/many%s.sh b/src/many%s.sh\n' "$i" "$i"
    printf 'index 0000000..1111111 100644\n--- /dev/null\n+++ b/src/many%s.sh\n' "$i"
    printf '@@ -0,0 +1,2 @@\n+# returns the count\n+fm_many%s() { echo %s; }\n' "$i" "$i"
  done
} > "$MANYDIFF"

UNIDIFF="$TMP_ROOT/unicode.diff"
cat > "$UNIDIFF" <<'EOF'
diff --git "a/docs/r\303\251sum\303\251.sh" "b/docs/r\303\251sum\303\251.sh"
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ "b/docs/r\303\251sum\303\251.sh"
@@ -0,0 +1,2 @@
+# returns the summary
+fm_resume() { echo summary }
EOF

R3DIFF="$TMP_ROOT/r3.diff"
cat > "$R3DIFF" <<'EOF'
diff --git a/docs/tools.md b/docs/tools.md
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ b/docs/tools.md
@@ -0,0 +1,10 @@
+# Supported tools
+
+The fleet supports exactly three harnesses: `claude`, `codex`, and `pi`.
+
+## Registry
+
+- `claude` - conversational work
+- `codex` - patch generation
+- `opencode` - editing
+- `pi` - supervision
EOF

SECRETDIFF="$TMP_ROOT/secret.diff"
cat > "$SECRETDIFF" <<'EOF'
diff --git a/tests/x.test.sh b/tests/x.test.sh
new file mode 100644
index 0000000..1111111 100644
--- /dev/null
+++ b/tests/x.test.sh
@@ -0,0 +1,14 @@
+# runs the tool against a live key
+run_it() {
+  out=$(env TYPESAFE_API_KEY="sk-live-REALKEY123" "$TOOL" check)
+}
+
+# builds the request payload for the classifier
+payload() {
+  client_secret: "zzz111"
+}
+
+# renders the values file the chart consumes
+values() {
+  db_password: unquotedhunter2
+}
EOF

check_env() {  # <probs-json> <command...>
  local probs=$1; shift
  env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="sk-test-SECRETKEY123" \
    FM_FAKE_JEV_RULES="$RULES" FM_FAKE_JEV_PROBS="$probs" "$@"
}

test_extraction_and_cutoffs() {
  local out rc
  out=$(check_env '{"r1":0.91,"r2":0.11,"r4":0.75}' "$TOOL" check --diff-file "$DIFF" --record "$RECORD" 2> "$TMP_ROOT/check.err"); rc=$?
  [ "$rc" -eq 0 ] || fail "check exits 0 (rc=$rc): $(cat "$TMP_ROOT/check.err")"
  echo "$out" | grep -q 'finding .* \[r1 src/thing.sh p=0.91 cutoff=0.5\]' \
    || fail "r1 violation above cutoff prints a finding: $out"
  echo "$out" | grep -q 'finding .* \[r4 test/thing.test.sh p=0.75 cutoff=0.6\]' \
    || fail "r4 violation above cutoff prints a finding: $out"
  echo "$out" | grep -q '\[r2 ' && fail "r2 below cutoff must not print a finding: $out"
  [ "$(jq -s 'length' "$RECORD")" -eq 3 ] || fail "three subjects recorded, one per rule"
  jq -e -s 'map(select(.rule == "r1")) | .[0].flagged == true' "$RECORD" >/dev/null \
    || fail "r1 0.91 >= 0.50 flags"
  jq -e -s 'map(select(.rule == "r2")) | .[0].flagged == false' "$RECORD" >/dev/null \
    || fail "r2 0.11 < 0.60 does not flag"
  jq -e -s 'map(select(.rule == "r4")) | .[0].flagged == true' "$RECORD" >/dev/null \
    || fail "r4 0.75 >= 0.60 flags"
  grep -q 'sekrit' "$RECORD" && fail ".env subject must never reach the record"
  grep -q 'hunter2' "$RECORD" && fail "a file under a secrets-like directory must never reach the record"
  grep -q 'spacedtenant42' "$RECORD" && fail "a secrets-like path containing a space must never reach the record"
  grep -q 'uppertenant43' "$RECORD" && fail "an upper-case secrets-like path component must never reach the record"
  grep -q 'SECRETKEY123' "$RECORD" && fail "API key must never reach the record"
  pass "extraction finds R1/R2/R4, excludes .env, and applies frozen cutoffs"
}

test_cutoff_boundary_flags() {
  local rec="$TMP_ROOT/boundary.jsonl" out
  out=$(check_env '{"r1":0.5,"r2":0.6,"r4":0.59}' "$TOOL" check --diff-file "$DIFF" --record "$rec" 2>/dev/null)
  echo "$out" | grep -q '\[r1 ' || fail "p == cutoff flags (r1 0.50 >= 0.50)"
  echo "$out" | grep -q '\[r2 ' || fail "p == cutoff flags (r2 0.60 >= 0.60)"
  echo "$out" | grep -q '\[r4 ' && fail "p just below cutoff must not flag (r4 0.59 < 0.60)"
  pass "probability equal to the cutoff flags, just below does not"
}

test_absent_key_skips_silently() {
  local rec="$TMP_ROOT/nokey.jsonl" out rc
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" "$TOOL" check --diff-file "$DIFF" --record "$rec" 2> "$TMP_ROOT/nokey.err"); rc=$?
  [ "$rc" -eq 0 ] || fail "absent key still exits 0 (rc=$rc)"
  [ -z "$out" ] || fail "absent key prints nothing on stdout: $out"
  [ -s "$TMP_ROOT/nokey.err" ] && fail "absent key prints nothing on stderr: $(cat "$TMP_ROOT/nokey.err")"
  [ -e "$rec" ] && fail "absent key writes no record"
  pass "absent TYPESAFE_API_KEY skips silently with exit 0 and no record"
}

test_record_never_carries_key() {
  jq -e -s 'all(.[]; (tostring | test("SECRETKEY123|sekrit") | not))' "$RECORD" >/dev/null \
    || fail "record must never carry the key or secret material"
  jq -e -s 'all(.[] | select(.kind == "check");
    has("id") and has("rule") and has("cutoff") and has("claim") and has("evidence")
    and has("probability") and has("flagged") and has("input_tokens") and has("cost_usd")
    and has("latency_ms") and (.model | type) == "string")' "$RECORD" >/dev/null \
    || fail "check lines carry the replayable fields"
  pass "record is replayable and never carries the key"
}

test_resolve_and_score() {
  # The record is the documented jsonl contract (docs/configuration.md "Jev
  # self-check record"); writing one here pins every scorer number by hand.
  local rec="$TMP_ROOT/score.jsonl" out
  cat > "$rec" <<'REC'
{"ts":"2026-01-01T00:00:00Z","run_id":"100","kind":"check","id":"100-1","rule":"r1","cutoff":0.5,"file":"a.sh","claim":"# returns zero","evidence":"fm_a() { return 1 }","probability":0.91,"flagged":true,"input_tokens":100,"cost_usd":0.00000420,"latency_ms":1,"model":"jev-1.13.0"}
{"ts":"2026-01-01T00:00:00Z","run_id":"100","kind":"check","id":"100-2","rule":"r2","cutoff":0.6,"file":"a.test.sh","claim":"it \"works\", {","evidence":"run_thing","probability":0.11,"flagged":false,"input_tokens":100,"cost_usd":0.00000420,"latency_ms":1,"model":"jev-1.13.0"}
{"ts":"2026-01-01T00:00:00Z","run_id":"100","kind":"check","id":"100-3","rule":"r4","cutoff":0.6,"file":"a.test.sh","claim":"FM_TIMEOUT=5","evidence":"sleep 60","probability":0.75,"flagged":true,"input_tokens":100,"cost_usd":0.00000420,"latency_ms":1,"model":"jev-1.13.0"}
REC
  FM_HOME="$HOME_DIR" "$TOOL" resolve --id 100-1 --verdict fixed --reason "rewrote comment" --record "$rec" >/dev/null \
    || fail "resolve accepts a fixed verdict"
  FM_HOME="$HOME_DIR" "$TOOL" resolve --id 100-1 --verdict maybe --record "$rec" 2>/dev/null \
    && fail "resolve refuses an unknown verdict"
  [ $? -eq 2 ] || fail "resolve misuse exits 2"
  FM_HOME="$HOME_DIR" "$TOOL" resolve --id 9999-1-7 --verdict fixed --reason x --record "$rec" 2>/dev/null \
    && fail "resolve refuses an id no finding has"
  FM_HOME="$HOME_DIR" "$TOOL" resolve --id 100-1 --verdict dismissed --reason again --record "$rec" 2>/dev/null \
    && fail "resolve refuses a second outcome for an already resolved finding"
  FM_HOME="$HOME_DIR" "$TOOL" resolve --id 100-2 --verdict fixed --record "$rec" 2>/dev/null \
    && fail "resolve refuses a subject that was never flagged"
  jq -e -s 'all(.[] | select(.kind == "outcome"); .rule != "")' "$rec" >/dev/null \
    || fail "no outcome is recorded without the rule it belongs to"
  out=$(FM_HOME="$HOME_DIR" "$TOOL" score --record "$rec")
  echo "$out" | grep -q 'runs=1 checks=3 flagged=2 fixed=1 dismissed=0 open=1' \
    || fail "score counts checks, flags, and outcomes: $out"
  echo "$out" | grep -qF 'rule r1: runs=1 checks=1 flagged=1 cost_usd=0.00000420 cost_per_run=4.2e-06 mean_latency_ms=1 fixed=1 dismissed=0 fixed_rate=1' \
    || fail "score reports per-rule cost, latency, and fixed-versus-dismissed rates: $out"
  echo "$out" | grep -qF 'rule r2: runs=1 checks=1 flagged=0 cost_usd=0.00000420 cost_per_run=4.2e-06 mean_latency_ms=1 fixed=0 dismissed=0 fixed_rate=n/a' \
    || fail "score reports n/a for a rule with no resolved findings: $out"
  pass "resolve records outcomes and score reports fixed-versus-dismissed rates"
}

test_quoted_non_ascii_path_is_decoded() {
  local rec="$TMP_ROOT/unicode.jsonl"
  check_env '{"r1":0.91}' "$TOOL" check --diff-file "$UNIDIFF" --record "$rec" >/dev/null 2>&1 \
    || fail "check exits 0 for a quoted non-ASCII path"
  jq -e -s '.[0].file == "docs/résumé.sh"' "$rec" >/dev/null \
    || fail "a git-quoted non-ASCII path is recorded decoded: $(jq -r -s '.[0].file' "$rec")"
  pass "a git-quoted non-ASCII path reaches the record as the real path"
}

test_shim_carries_the_request() {
  local rec="$TMP_ROOT/shim.jsonl" out
  out=$(env FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="sk-test-SECRETKEY123" FM_FAKE_JEV_RULES="$RULES" \
    FM_FAKE_JEV_PROBS='{"r1":0.91,"r2":0.11,"r4":0.75}' FM_FAKE_JEV_TOKENS=123 \
    "$TOOL" check --diff-file "$DIFF" --record "$rec" 2>/dev/null)
  echo "$out" | grep -q '\[r1 src/thing.sh p=0.91 cutoff=0.5\]' \
    || fail "a shim answer above the cutoff prints a finding: $out"
  jq -e -s 'all(.[] | select(.kind == "check"); .input_tokens == 123)' "$rec" >/dev/null \
    || fail "the shim's usage reaches the record"
  grep -q 'SECRETKEY123' "$rec" && fail "the key must never reach the record"
  pass "requests go through the call shim and its answers reach the record"
}

test_shim_unavailable_raises_no_finding() {
  local rec="$TMP_ROOT/unavail.jsonl" out rc
  out=$(env FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="sk-test-SECRETKEY123" FM_FAKE_JEV_RULES="$RULES" \
    FM_FAKE_JEV_PROBS='{"r1":0.91}' FM_FAKE_JEV_FAIL=1 \
    "$TOOL" check --diff-file "$DIFF" --record "$rec" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "an unavailable shim still exits 0 (rc=$rc)"
  echo "$out" | grep -q 'finding' && fail "an unavailable shim raises no finding: $out"
  jq -e -s 'all(.[] | select(.kind == "check"); .probability == null and .flagged == false)' "$rec" >/dev/null \
    || fail "an unavailable shim records a null probability"
  pass "an unavailable shim is recorded and never raises a finding"
}

test_malformed_answer_is_recorded_unavailable() {
  local rec="$TMP_ROOT/malformed.jsonl" out rc
  out=$(env FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="sk-test-SECRETKEY123" FM_FAKE_JEV_RULES="$RULES" \
    FM_FAKE_JEV_PROBS='{"r1":0.91,"r2":0.11,"r4":0.75}' FM_FAKE_JEV_MALFORMED=1 \
    "$TOOL" check --diff-file "$DIFF" --record "$rec" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || fail "a malformed answer still exits 0 (rc=$rc)"
  echo "$out" | grep -q 'finding' && fail "a non-numeric probability raises no finding: $out"
  [ "$(jq -s 'map(select(.kind == "check")) | length' "$rec")" -eq 3 ] \
    || fail "every subject still gets one record line: $(cat "$rec")"
  jq -e -s 'all(.[] | select(.kind == "check"); .probability == null and .flagged == false and .input_tokens == 0)' "$rec" >/dev/null \
    || fail "a malformed answer records a null probability and no tokens: $(cat "$rec")"
  pass "a non-numeric answer field is recorded as unavailable, never flagged"
}

test_parallel_record_lines_stay_whole() {
  local rec="$TMP_ROOT/big.jsonl" out
  out=$(check_env '{"r1":0.91}' "$TOOL" check --diff-file "$BIGDIFF" --record "$rec" 2>&1)
  [ "$(jq -s 'map(select(.kind == "check")) | length' "$rec")" -eq 8 ] \
    || fail "every parallel subject lands as one parseable record line: $out"
  jq -e -s 'all(.[] | select(.kind == "check"); (.evidence | length) > 500)' "$rec" >/dev/null \
    || fail "the oversized evidence survived into the record intact"
  [ "$(awk '{ if (length > m) m = length } END { print m + 0 }' "$rec")" -gt 4096 ] \
    || fail "the fixture must produce record lines past one stdio buffer"
  pass "parallel runs append whole record lines, never interleaved fragments"
}

test_interrupted_run_stops_and_keeps_its_record_lines() {
  local rec="$TMP_ROOT/interrupted.jsonl" out="$TMP_ROOT/interrupted.out" pid t0 id
  env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="sk-test-SECRETKEY123" \
    FM_FAKE_JEV_RULES="$RULES" FM_FAKE_JEV_PROBS='{"r1":0.91}' FM_FAKE_JEV_SLEEP=4 \
    "$TOOL" check --diff-file "$MANYDIFF" --record "$rec" > "$out" 2>/dev/null &
  pid=$!
  sleep 6
  t0=$SECONDS
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  [ $((SECONDS - t0)) -le 1 ] \
    || fail "SIGTERM must stop the run, not let it finish the remaining subjects"
  [ -s "$rec" ] || fail "an interrupted run keeps the lines its finished jobs produced"
  jq -e -s 'length >= 8 and all(.[]; .kind == "check")' "$rec" >/dev/null \
    || fail "the kept lines are whole check records: $(wc -l < "$rec") line(s)"
  sleep 4
  while read -r id; do
    [ -n "$id" ] || continue
    jq -e -s --arg id "$id" 'any(.[]; .kind == "check" and .id == $id)' "$rec" >/dev/null \
      || fail "printed finding $id has no record line, so it can never be resolved"
  done < <(sed -n 's/^jev-lint finding \([^ ]*\) .*/\1/p' "$out")
  pass "an interrupted run stops at once and records every finding it printed"
}

test_shim_reads_the_key_from_the_home_env() {
  local home2="$TMP_ROOT/home-dotenv" rec="$TMP_ROOT/dotenv.jsonl" out
  mkdir -p "$home2/data"
  printf 'TYPESAFE_API_KEY=sk-dotenv-SECRETKEY456\n' > "$home2/.env"
  out=$(env -u FM_HOME -u TYPESAFE_API_KEY FM_ROOT_OVERRIDE="$home2" FM_FAKE_JEV_RULES="$RULES" \
    FM_FAKE_JEV_PROBS='{"r1":0.91,"r2":0.11,"r4":0.75}' "$TOOL" check --diff-file "$DIFF" --record "$rec" 2>&1)
  echo "$out" | grep -q '\[r1 src/thing.sh p=0.91 cutoff=0.5\]' \
    || fail "the request reaches the shim when the key lives only in the home .env: $out"
  echo "$out" | grep -q 'SECRETKEY456' && fail "the key must never be printed"
  grep -q 'SECRETKEY456' "$rec" && fail "the key must never reach the record"
  pass "a key held only in the home .env still reaches the shim"
}

test_disabled_rule_is_skipped() {
  local rules="$TMP_ROOT/rules.json" rec="$TMP_ROOT/disabled.jsonl" out
  jq '.rules.r4.enabled = false' "$RULES" > "$rules"
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="sk-test-SECRETKEY123" \
    FM_FAKE_JEV_RULES="$rules" FM_FAKE_JEV_PROBS='{"r1":0.91,"r2":0.11,"r4":0.99}' \
    FM_JEV_LINT_RULES="$rules" "$TOOL" check --diff-file "$DIFF" --record "$rec" 2>/dev/null)
  echo "$out" | grep -q '\[r4 ' && fail "disabled r4 must not run even at p=0.99"
  [ "$(jq -s 'length' "$rec")" -eq 2 ] || fail "disabled r4 records nothing"
  pass "flipping enabled to false removes a rule in one data line"
}

test_r3_enumeration_subjects() {
  local rec="$TMP_ROOT/r3.jsonl" out
  out=$(check_env '{"r3":0.5}' "$TOOL" check --diff-file "$R3DIFF" --record "$rec" 2>/dev/null)
  [ "$(jq -s 'length' "$rec")" -eq 2 ] || fail "r3 yields the inline enumeration and the bullet run"
  jq -e -s 'all(.[]; .rule == "r3" and .cutoff == 0.2 and .flagged == true)' "$rec" >/dev/null \
    || fail "r3 0.50 >= 0.20 flags with the frozen cutoff"
  echo "$out" | grep -q '\[r3 docs/tools.md' || fail "r3 findings print with rule and file: $out"
  grep -q 'SECRETKEY123' "$rec" && fail "API key must never reach the record"
  local low="$TMP_ROOT/r3-low.jsonl"
  out=$(check_env '{"r3":0.18}' "$TOOL" check --diff-file "$R3DIFF" --record "$low" 2>/dev/null)
  echo "$out" | grep -q 'finding' && fail "r3 0.18 < 0.20 must stay silent (version-string drift band)"
  pass "r3 extracts enumerations and applies the frozen 0.20 cutoff"
}

test_secret_content_is_dropped() {
  local rec="$TMP_ROOT/secret.jsonl" out rc
  out=$(env -u TYPESAFE_API_KEY -u FM_FAKE_JEV_PROBS FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="sk-test-SECRETKEY123" \
    "$TOOL" check --diff-file "$SECRETDIFF" --record "$rec" 2> "$TMP_ROOT/secret.err"); rc=$?
  [ "$rc" -eq 0 ] || fail "check still exits 0 (rc=$rc): $(cat "$TMP_ROOT/secret.err")"
  echo "$out" | grep -q 'finding' && fail "a dropped subject yields no finding: $out"
  grep -q 'REALKEY123' "$rec" && fail "a dropped subject must never reach the record"
  grep -q 'zzz111' "$rec" && fail "a lowercase secret assignment must never reach the record"
  grep -q 'unquotedhunter2' "$rec" && fail "an unquoted lowercase secret assignment must never reach the record"
  [ "$(jq -s 'map(select(.kind == "check")) | length' "$rec")" -eq 0 ] \
    || fail "a dropped subject is not recorded as a checked subject"
  jq -e -s 'map(select(.kind == "dropped")) | .[0].count == 3' "$rec" >/dev/null \
    || fail "the run records the dropped count alone: $(cat "$rec")"
  pass "diff lines carrying a key or a quoted or unquoted secret are dropped, not sent"
}

test_extraction_and_cutoffs
test_secret_content_is_dropped
test_cutoff_boundary_flags
test_r3_enumeration_subjects
test_absent_key_skips_silently
test_record_never_carries_key
test_resolve_and_score
test_disabled_rule_is_skipped
test_quoted_non_ascii_path_is_decoded
test_shim_carries_the_request
test_shim_unavailable_raises_no_finding
test_shim_reads_the_key_from_the_home_env
test_malformed_answer_is_recorded_unavailable
test_parallel_record_lines_stay_whole
test_interrupted_run_stops_and_keeps_its_record_lines
