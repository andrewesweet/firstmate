#!/usr/bin/env bash
# Behavior tests for bin/fm-remote-inherit.sh generation bookkeeping.
#
# The receiver records each generation in a receipt beside the destination.
# A transfer interrupted after the receipt is staged but before the
# destination is updated must retry as ordinary convergence: the untouched
# previous copy is not drift and is never quarantined, and real drift after
# an interruption still is.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-remote-inherit)

RECEIPT_NAME=".fm-inherit-captain-shared.md.generation"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data" "$home/config"
  printf '%s\n' "$home"
}

remote_put() {  # <home> <payload-file> <generation>
  local home=$1 payload=$2 generation=$3 bytes hash
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash inheritance payload"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
    put data/captain-shared.md "$bytes" "$hash" "$generation" < "$payload" 2>&1
}

# Run the receiver with a counting mv shim whose <fail-on>-th call fails, so
# the run dies at that exact publication step and leaves the on-disk state a
# crash at that point would leave.
interrupted_put() {  # <home> <payload-file> <generation> <fail-on-call>
  local home=$1 payload=$2 generation=$3 fail_on=$4 fakebin counter real_mv out rc=0
  fakebin="$TMP_ROOT/failing-mv-bin"
  counter="$TMP_ROOT/mv-calls"
  real_mv=$(command -v mv)
  mkdir -p "$fakebin"
  rm -f -- "$counter"
  cat > "$fakebin/mv" <<EOF
#!/usr/bin/env bash
calls=\$(cat '$counter' 2>/dev/null || printf '0')
calls=\$((calls + 1))
printf '%s\n' "\$calls" > '$counter'
if [ "\$calls" -eq '$fail_on' ]; then exit 1; fi
exec '$real_mv' "\$@"
EOF
  chmod +x "$fakebin/mv"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
    put data/captain-shared.md \
    "$(LC_ALL=C wc -c < "$payload" | tr -d ' ')" \
    "$(fm_inherit_sha256 "$payload")" "$generation" < "$payload" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted put unexpectedly succeeded: $out"
}

quarantine_count() {
  find "$1/data" -name 'captain-shared.md.remote-quarantine-*' | wc -l | tr -d ' '
}

assert_receipt_applied_only() {  # <home>
  local receipt="$1/data/$RECEIPT_NAME"
  [ -f "$receipt" ] || fail "generation receipt is missing after a completed transfer"
  assert_equals "applied" "$(head -n 1 "$receipt")" \
    "receipt should end as a single applied record"
  [ "$(grep -c '^pending$' "$receipt" || true)" -eq 0 ] \
    || fail "receipt should not keep a pending record after the destination holds the generation"
}

test_interrupted_transfer_retry_neither_quarantines_previous_copy_nor_loses_new_one() {
  local home payload_v1 payload_v2 out
  home=$(new_home interrupted-retry)
  payload_v1="$TMP_ROOT/interrupted-retry-v1.md"
  payload_v2="$TMP_ROOT/interrupted-retry-v2.md"
  printf 'inherited v1\n' > "$payload_v1"
  printf 'inherited v2\n' > "$payload_v2"

  out=$(remote_put "$home" "$payload_v1" 1) || fail "first inherit failed: $out"
  assert_contains "$out" "pushed: data/captain-shared.md" "first inherit did not publish"

  # Interrupt between staging the receipt and publishing the destination.
  interrupted_put "$home" "$payload_v2" 2 2
  cmp -s "$payload_v1" "$home/data/captain-shared.md" \
    || fail "interrupted transfer must leave the previous copy in place"
  [ "$(quarantine_count "$home")" -eq 0 ] \
    || fail "the interruption itself created a quarantine artifact"

  out=$(remote_put "$home" "$payload_v2" 2) || fail "retry after interruption failed: $out"
  assert_not_contains "$out" "quarantined:" \
    "retry after an interrupted transfer quarantined the untouched previous copy"
  [ "$(quarantine_count "$home")" -eq 0 ] \
    || fail "retry after an interrupted transfer left a recovery copy of the previous generation"
  cmp -s "$payload_v2" "$home/data/captain-shared.md" \
    || fail "retry after an interrupted transfer did not install the new generation"
  assert_equals "444" "$(file_mode "$home/data/captain-shared.md")" \
    "retry did not restore the read-only shared mode"
  assert_receipt_applied_only "$home"
  pass "retry after an interrupted transfer converges without quarantining the previous copy"
}

test_interrupted_transfer_retry_still_quarantines_real_drift() {
  local home payload_v1 payload_v2 out qpath
  home=$(new_home interrupted-drift)
  payload_v1="$TMP_ROOT/interrupted-drift-v1.md"
  payload_v2="$TMP_ROOT/interrupted-drift-v2.md"
  printf 'inherited v1\n' > "$payload_v1"
  printf 'inherited v2\n' > "$payload_v2"

  out=$(remote_put "$home" "$payload_v1" 1) || fail "first inherit failed: $out"
  interrupted_put "$home" "$payload_v2" 2 2

  chmod u+w "$home/data/captain-shared.md"
  printf 'captain local edit\n' > "$home/data/captain-shared.md"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$home/data/captain-shared.md"

  out=$(remote_put "$home" "$payload_v2" 2) || fail "drift retry failed: $out"
  assert_contains "$out" "quarantined:" \
    "a locally edited destination was replaced without a recovery copy"
  [ "$(quarantine_count "$home")" -eq 1 ] \
    || fail "real drift after an interruption should leave exactly one recovery copy"
  qpath=$(find "$home/data" -name 'captain-shared.md.remote-quarantine-*')
  assert_grep "captain local edit" "$qpath" "quarantine lost the edited bytes"
  cmp -s "$payload_v2" "$home/data/captain-shared.md" \
    || fail "drift retry did not install the new generation"
  pass "retry after an interruption still quarantines a locally edited destination"
}

test_interrupted_transfer_after_publication_retry_reports_unchanged() {
  local home payload_v1 payload_v2 out
  home=$(new_home interrupted-promote)
  payload_v1="$TMP_ROOT/interrupted-promote-v1.md"
  payload_v2="$TMP_ROOT/interrupted-promote-v2.md"
  printf 'inherited v1\n' > "$payload_v1"
  printf 'inherited v2\n' > "$payload_v2"

  out=$(remote_put "$home" "$payload_v1" 1) || fail "first inherit failed: $out"

  # Interrupt between publishing the destination and promoting the receipt.
  interrupted_put "$home" "$payload_v2" 2 3
  cmp -s "$payload_v2" "$home/data/captain-shared.md" \
    || fail "the destination should already hold the new payload after the transfer step"

  out=$(remote_put "$home" "$payload_v2" 2) || fail "retry after publication failed: $out"
  assert_contains "$out" "unchanged: data/captain-shared.md" \
    "retry after a published-but-unpromoted transfer should report unchanged"
  assert_not_contains "$out" "quarantined:" \
    "retry after publication quarantined the payload it transferred itself"
  [ "$(quarantine_count "$home")" -eq 0 ] \
    || fail "retry after publication left a quarantine artifact"
  assert_receipt_applied_only "$home"
  pass "retry after a published-but-unpromoted transfer converges quietly"
}

test_newer_generation_after_interrupted_publication_does_not_quarantine_transferred_payload() {
  local home payload_v1 payload_v2 payload_v3 out
  home=$(new_home interrupted-newer)
  payload_v1="$TMP_ROOT/interrupted-newer-v1.md"
  payload_v2="$TMP_ROOT/interrupted-newer-v2.md"
  payload_v3="$TMP_ROOT/interrupted-newer-v3.md"
  printf 'inherited v1\n' > "$payload_v1"
  printf 'inherited v2\n' > "$payload_v2"
  printf 'inherited v3\n' > "$payload_v3"

  out=$(remote_put "$home" "$payload_v1" 1) || fail "first inherit failed: $out"
  interrupted_put "$home" "$payload_v2" 2 3

  out=$(remote_put "$home" "$payload_v3" 3) || fail "newer generation push failed: $out"
  assert_not_contains "$out" "quarantined:" \
    "a newer push quarantined the payload an earlier interrupted transfer published"
  [ "$(quarantine_count "$home")" -eq 0 ] \
    || fail "a newer push left a recovery copy of legitimately transferred bytes"
  cmp -s "$payload_v3" "$home/data/captain-shared.md" \
    || fail "newer generation push did not install its payload"
  assert_receipt_applied_only "$home"
  pass "a newer push accepts a destination holding the interrupted transfer's payload"
}

test_old_format_receipt_is_treated_as_applied() {
  local home payload_v1 payload_v2 bytes_v1 hash_v1 out
  home=$(new_home old-format-receipt)
  payload_v1="$TMP_ROOT/old-format-v1.md"
  payload_v2="$TMP_ROOT/old-format-v2.md"
  printf 'inherited v1\n' > "$payload_v1"
  printf 'inherited v2\n' > "$payload_v2"

  out=$(remote_put "$home" "$payload_v1" 1) || fail "first inherit failed: $out"

  # Downgrade the receipt to the pre-pending four-line format: the state the
  # destination is already in from every receiver revision before pending
  # bookkeeping existed.
  bytes_v1=$(LC_ALL=C wc -c < "$payload_v1" | tr -d ' ')
  hash_v1=$(fm_inherit_sha256 "$payload_v1")
  printf '%s\n%s\n%s\n%s\n' 1 "$bytes_v1" "$hash_v1" put \
    > "$home/data/$RECEIPT_NAME"

  out=$(remote_put "$home" "$payload_v2" 2) || fail "put after old-format receipt failed: $out"
  assert_not_contains "$out" "quarantined:" \
    "an old-format receipt must mean applied, not drift"
  [ "$(quarantine_count "$home")" -eq 0 ] \
    || fail "an old-format receipt led to a quarantine artifact"
  cmp -s "$payload_v2" "$home/data/captain-shared.md" \
    || fail "put after an old-format receipt did not install the new generation"
  pass "an old-format four-line receipt is read as an applied generation"
}

test_second_interruption_does_not_quarantine_earlier_interrupted_payload() {
  local home payload_v1 payload_v2 payload_v3 out
  home=$(new_home interrupted-twice)
  payload_v1="$TMP_ROOT/interrupted-twice-v1.md"
  payload_v2="$TMP_ROOT/interrupted-twice-v2.md"
  payload_v3="$TMP_ROOT/interrupted-twice-v3.md"
  printf 'inherited v1\n' > "$payload_v1"
  printf 'inherited v2\n' > "$payload_v2"
  printf 'inherited v3\n' > "$payload_v3"

  out=$(remote_put "$home" "$payload_v1" 1) || fail "first inherit failed: $out"
  # Generation 2 publishes the destination, then dies before promotion.
  interrupted_put "$home" "$payload_v2" 2 3
  # Generation 3 stages its receipt, then dies before publication.
  interrupted_put "$home" "$payload_v3" 3 2
  cmp -s "$payload_v2" "$home/data/captain-shared.md" \
    || fail "the second interruption should leave generation 2's payload in place"

  out=$(remote_put "$home" "$payload_v3" 3) || fail "retry after two interruptions failed: $out"
  assert_not_contains "$out" "quarantined:" \
    "retry after two interruptions quarantined the payload generation 2 transferred"
  [ "$(quarantine_count "$home")" -eq 0 ] \
    || fail "retry after two interruptions left a recovery copy of transferred bytes"
  cmp -s "$payload_v3" "$home/data/captain-shared.md" \
    || fail "retry after two interruptions did not install generation 3"
  assert_receipt_applied_only "$home"
  pass "a second interruption keeps the earlier interrupted payload recognized as published"
}

assert_receipt_refused() {  # <home> <payload-file> <generation> <message>
  local out rc=0
  out=$(remote_put "$1" "$2" "$3") || rc=$?
  [ "$rc" -ne 0 ] || fail "$4: $out"
  assert_contains "$out" "inheritance generation record is malformed" "$4"
}

test_malformed_receipt_shapes_are_refused() {
  local home payload hash record
  home=$(new_home malformed-receipt)
  payload="$TMP_ROOT/malformed-receipt.md"
  printf 'inherited v1\n' > "$payload"
  hash=$(fm_inherit_sha256 "$payload")
  record="1
13
$hash
put"

  printf 'applied\n%s' "$record" > "$home/data/$RECEIPT_NAME"
  assert_receipt_refused "$home" "$payload" 2 \
    "a receipt without a trailing newline was accepted"

  printf 'pending\n%s\npending\n%s\n' "$record" "$record" > "$home/data/$RECEIPT_NAME"
  assert_receipt_refused "$home" "$payload" 2 \
    "a ten-line receipt led by a pending record was accepted"

  printf 'applied\n%s\napplied\n%s\n' "$record" "$record" > "$home/data/$RECEIPT_NAME"
  assert_receipt_refused "$home" "$payload" 2 \
    "a ten-line receipt whose second record is not pending was accepted"

  [ ! -e "$home/data/captain-shared.md" ] \
    || fail "a refused receipt still published the destination"
  pass "malformed receipt shapes fail closed"
}

test_interrupted_transfer_retry_neither_quarantines_previous_copy_nor_loses_new_one
test_interrupted_transfer_retry_still_quarantines_real_drift
test_interrupted_transfer_after_publication_retry_reports_unchanged
test_newer_generation_after_interrupted_publication_does_not_quarantine_transferred_payload
test_old_format_receipt_is_treated_as_applied
test_second_interruption_does_not_quarantine_earlier_interrupted_payload
test_malformed_receipt_shapes_are_refused

echo "# all fm-remote-inherit tests passed"
