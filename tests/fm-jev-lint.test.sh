#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-lint.sh (advisory worker self-check).
#
# Drives the public argv interface with a fixture diff, a stubbed Jev answer
# source, and a scratch record. No network, no key on the wire: a fakebin curl
# that fails loudly guards every test, so any production network path attempt
# fails the test instead of calling out. The stub probabilities pin cutoff
# application exactly, and the scorer test hand-computes every number from its
# fixture record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-lint)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
printf '#!/usr/bin/env bash\necho "fake curl must never run" >&2\nexit 42\n' > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"
RECORD="$TMP_ROOT/record.jsonl"
STUB="$TMP_ROOT/stub.json"
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
EOF

printf '{"r1":0.91,"r2":0.11,"r4":0.75}' > "$STUB"

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

check_env() {
  env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" FM_JEV_LINT_STUB="$STUB" TYPESAFE_API_KEY="sk-test-SECRETKEY123" "$@"
}

test_extraction_and_cutoffs() {
  local out rc
  out=$(check_env "$TOOL" check --diff-file "$DIFF" --record "$RECORD" 2> "$TMP_ROOT/check.err"); rc=$?
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
  grep -q 'SECRETKEY123' "$RECORD" && fail "API key must never reach the record"
  pass "extraction finds R1/R2/R4, excludes .env, and applies frozen cutoffs"
}

test_cutoff_boundary_flags() {
  local rec="$TMP_ROOT/boundary.jsonl" stub="$TMP_ROOT/boundary-stub.json" out
  printf '{"r1":0.5,"r2":0.6,"r4":0.59}' > "$stub"
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" FM_JEV_LINT_STUB="$stub" TYPESAFE_API_KEY="sk-test-SECRETKEY123" \
    "$TOOL" check --diff-file "$DIFF" --record "$rec" 2>/dev/null)
  echo "$out" | grep -q '\[r1 ' || fail "p == cutoff flags (r1 0.50 >= 0.50)"
  echo "$out" | grep -q '\[r2 ' || fail "p == cutoff flags (r2 0.60 >= 0.60)"
  echo "$out" | grep -q '\[r4 ' && fail "p just below cutoff must not flag (r4 0.59 < 0.60)"
  pass "probability equal to the cutoff flags, just below does not"
}

test_absent_key_skips_silently() {
  local rec="$TMP_ROOT/nokey.jsonl" out rc
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" "$TOOL" check --diff-file "$DIFF" --record "$rec" 2> "$TMP_ROOT/nokey.err"); rc=$?
  [ "$rc" -eq 0 ] || fail "absent key still exits 0 (rc=$rc)"
  echo "$out" | grep -q 'finding' && fail "absent key prints no findings"
  [ -e "$rec" ] && fail "absent key writes no record"
  grep -q 'skipped' "$TMP_ROOT/nokey.err" || fail "absent key explains the skip on stderr"
  pass "absent TYPESAFE_API_KEY skips with exit 0 and no record"
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
  local id out
  id=$(jq -r -s 'map(select(.kind == "check" and .flagged)) | .[0].id' "$RECORD")
  [ -n "$id" ] && [ "$id" != "null" ] || fail "fixture needs a flagged finding to resolve"
  FM_HOME="$HOME_DIR" "$TOOL" resolve --id "$id" --verdict fixed --reason "rewrote comment" --record "$RECORD" >/dev/null \
    || fail "resolve accepts a fixed verdict"
  FM_HOME="$HOME_DIR" "$TOOL" resolve --id "$id" --verdict maybe --record "$RECORD" 2>/dev/null \
    && fail "resolve refuses an unknown verdict"
  [ $? -eq 2 ] || fail "resolve misuse exits 2"
  out=$(FM_HOME="$HOME_DIR" "$TOOL" score --record "$RECORD")
  echo "$out" | grep -q 'runs=1 checks=3 flagged=2 fixed=1 dismissed=0 open=1' \
    || fail "score counts checks, flags, and outcomes: $out"
  echo "$out" | grep -qE 'rule r1: runs=1 checks=1 flagged=1 cost_usd=[0-9.e-]+ cost_per_run=[0-9.e-]+ mean_latency_ms=[0-9]+ fixed=1 dismissed=0 fixed_rate=1' \
    || fail "score reports per-rule cost, latency, and fixed-versus-dismissed rates: $out"
  echo "$out" | grep -qE 'rule r2: .* fixed=0 dismissed=0 fixed_rate=n/a' \
    || fail "score reports n/a for a rule with no resolved findings: $out"
  pass "resolve records outcomes and score reports fixed-versus-dismissed rates"
}

test_disabled_rule_is_skipped() {
  local rules="$TMP_ROOT/rules.json" rec="$TMP_ROOT/disabled.jsonl" stub="$TMP_ROOT/dis-stub.json" out
  jq '.rules.r4.enabled = false' "$ROOT/bin/fm-jev-lint-rules.json" > "$rules"
  printf '{"r1":0.91,"r2":0.11,"r4":0.99}' > "$stub"
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" FM_JEV_LINT_STUB="$stub" FM_JEV_LINT_RULES="$rules" \
    TYPESAFE_API_KEY="sk-test-SECRETKEY123" "$TOOL" check --diff-file "$DIFF" --record "$rec" 2>/dev/null)
  echo "$out" | grep -q '\[r4 ' && fail "disabled r4 must not run even at p=0.99"
  [ "$(jq -s 'length' "$rec")" -eq 2 ] || fail "disabled r4 records nothing"
  pass "flipping enabled to false removes a rule in one data line"
}

test_r3_enumeration_subjects() {
  local rec="$TMP_ROOT/r3.jsonl" stub="$TMP_ROOT/r3-stub.json" out
  printf '{"r3":0.5}' > "$stub"
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" FM_JEV_LINT_STUB="$stub" TYPESAFE_API_KEY="sk-test-SECRETKEY123" \
    "$TOOL" check --diff-file "$R3DIFF" --record "$rec" 2>/dev/null)
  [ "$(jq -s 'length' "$rec")" -eq 2 ] || fail "r3 yields the inline enumeration and the bullet run"
  jq -e -s 'all(.[]; .rule == "r3" and .cutoff == 0.2 and .flagged == true)' "$rec" >/dev/null \
    || fail "r3 0.50 >= 0.20 flags with the frozen cutoff"
  echo "$out" | grep -q '\[r3 docs/tools.md' || fail "r3 findings print with rule and file: $out"
  grep -q 'SECRETKEY123' "$rec" && fail "API key must never reach the record"
  local low="$TMP_ROOT/r3-low.jsonl" lowstub="$TMP_ROOT/r3-low-stub.json"
  printf '{"r3":0.18}' > "$lowstub"
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$HOME_DIR" FM_JEV_LINT_STUB="$lowstub" TYPESAFE_API_KEY="sk-test-SECRETKEY123" \
    "$TOOL" check --diff-file "$R3DIFF" --record "$low" 2>/dev/null)
  echo "$out" | grep -q 'finding' && fail "r3 0.18 < 0.20 must stay silent (version-string drift band)"
  pass "r3 extracts enumerations and applies the frozen 0.20 cutoff"
}

test_secret_content_is_dropped() {
  local rec="$TMP_ROOT/secret.jsonl" out rc
  out=$(env -u TYPESAFE_API_KEY -u FM_JEV_LINT_STUB FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="sk-test-SECRETKEY123" \
    "$TOOL" check --diff-file "$SECRETDIFF" --record "$rec" 2> "$TMP_ROOT/secret.err"); rc=$?
  [ "$rc" -eq 0 ] || fail "check still exits 0 (rc=$rc): $(cat "$TMP_ROOT/secret.err")"
  grep -q 'fake curl must never run' "$TMP_ROOT/secret.err" \
    && fail "a subject carrying a key must never reach the network"
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
