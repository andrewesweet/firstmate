#!/usr/bin/env bash
# tests/fm-remote-secondmate-relaunch.test.sh - regression coverage for
# bin/fm-remote-secondmate-relaunch.sh: the parent-side tool an operator runs
# to move a remote secondmate onto a new harness, model, or effort.
#
# Reproduces the observed defect: running
# bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch <id> <harness>
# <model> <effort> relaunches the agent on its host, but that host-local verb
# can only rewrite its own endpoint record. The parent's own state/<id>.meta
# kept naming the runtime the mate used to run. The wrapper drives the same
# host-local relaunch and then republishes this home's own record from the
# identity the host confirmed.
#
# The remote transport is faked at the SSH boundary, exactly as the other
# remote-secondmate suites fake it, rather than exercising a real host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }
REAL_SLEEP=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

TMP=$(fm_test_tmproot fm-remote-secondmate-relaunch)
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"

printf -- '- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS; projects: alpha; added 2026-08-01)\n' \
  > "$HOME_DIR/data/secondmates.md"

reset_meta() {
  fm_write_meta "$HOME_DIR/state/ios.meta" \
    "window=remote:ios" \
    "endpoint_task_id=ios" \
    "worktree=/srv/fm-home" \
    "project=/srv/fm" \
    "harness=pi" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "model=openai-codex/gpt-5.6-sol" \
    "effort=medium" \
    "home=/srv/fm-home" \
    "projects=alpha" \
    "remote_host=remote-mac" \
    "remote_root=/srv/fm" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
}

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..5]);
' "$argv_b64")
IFS=$'\t' read -r cmd action id harness model effort <<EOF
$command_fields
EOF
[ "$cmd" = fm-remote-secondmate-control.sh ] || exit 93
[ "$action" = relaunch ] || exit 94
case "$FM_FAKE_RELAUNCH_MODE" in
  refuse)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  confirm-other)
    harness=claude
    model=claude-opus-5-5
    effort=medium
    ;;
  race)
    printf '%s\n' "$harness" > "$FM_FAKE_RACE_DIR/endpoint"
    : > "$FM_FAKE_RACE_DIR/$harness-mutated"
    if [ "$harness" = claude ]; then
      i=0
      max_polls=$((${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120} * 100))
      while [ ! -e "$FM_FAKE_RACE_DIR/release-claude" ] && [ "$i" -lt "$max_polls" ]; do
        sleep 0.01
        i=$((i + 1))
      done
      [ -e "$FM_FAKE_RACE_DIR/release-claude" ] || exit 95
    fi
    ;;
esac
printf 'relaunched %s harness=%s from=pi model=%s effort=%s backend=herdr endpoint=fm-remote:w1:p1 worktree=/srv/fm-home\n' \
  "$id" "$harness" "$model" "$effort"
printf 'schema=fm-remote-secondmate-control.v1\n'
printf 'backend=herdr\n'
printf 'target=fm-remote:w1:p1\n'
printf 'herdr_session=fm-remote\n'
printf 'harness=%s\n' "$harness"
printf 'model=%s\n' "$model"
printf 'effort=%s\n' "$effort"
SH
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_SLEEP_LOG:-}" ]; then
  printf '%s\n' "$1" >> "$FM_FAKE_SLEEP_LOG"
fi
exec "$FM_FAKE_REAL_SLEEP" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh" "$FAKEBIN/sleep"

run_relaunch() {  # <args...>
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_REAL_SLEEP="$REAL_SLEEP" FM_FAKE_SLEEP_LOG="${FM_FAKE_SLEEP_LOG:-}" \
    FM_FAKE_RELAUNCH_MODE="${FM_FAKE_RELAUNCH_MODE:-}" \
    FM_FAKE_RACE_DIR="${FM_FAKE_RACE_DIR:-}" \
    "$ROOT/bin/fm-remote-secondmate-relaunch.sh" "$@" 2>&1
}

wait_for_process_path() {  # <path> <pid>
  local path=$1 pid=$2 polls=0 max_polls
  max_polls=$((FM_TEST_STUB_MAX_BLOCK_SECONDS * 100))
  while [ ! -e "$path" ] && kill -0 "$pid" 2>/dev/null && [ "$polls" -lt "$max_polls" ]; do
    "$REAL_SLEEP" 0.01
    polls=$((polls + 1))
  done
  [ -e "$path" ]
}

wait_for_process_line() {  # <line> <file> <pid>
  local line=$1 file=$2 pid=$3 polls=0 max_polls
  max_polls=$((FM_TEST_STUB_MAX_BLOCK_SECONDS * 100))
  while ! grep -Fx -- "$line" "$file" >/dev/null 2>&1 \
    && kill -0 "$pid" 2>/dev/null && [ "$polls" -lt "$max_polls" ]; do
    "$REAL_SLEEP" 0.01
    polls=$((polls + 1))
  done
  grep -Fx -- "$line" "$file" >/dev/null 2>&1
}

OUT=$(run_relaunch ios claude default); RC=$?
expect_code 2 "$RC" "wrong arity should report usage"
assert_contains "$OUT" \
  "Usage: fm-remote-secondmate-relaunch.sh <id> <harness> <model|default|-> <effort|default|->" \
  "wrong arity should print callable syntax"
pass "wrong arity prints remote relaunch syntax"

# --- a successful relaunch republishes the parent's own route record --------
reset_meta
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed"$'\n'"$OUT"
assert_contains "$OUT" "relaunched ios harness=claude" \
  "the wrapper should still print the host's own confirmation line"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed model"
assert_grep 'effort=medium' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed effort"
assert_no_grep 'harness=pi' "$HOME_DIR/state/ios.meta" \
  "the stale runtime should not still be recorded"
assert_no_grep 'model=openai-codex/gpt-5.6-sol' "$HOME_DIR/state/ios.meta" \
  "the stale model should not still be recorded"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" \
  "unrelated route fields must survive the update"
assert_grep 'window=remote:ios' "$HOME_DIR/state/ios.meta" \
  "unrelated identity fields must survive the update"
pass "a successful remote relaunch republishes the parent's harness, model, and effort"

# --- the parent records what the host confirmed, not what it was asked ------
reset_meta
FM_FAKE_RELAUNCH_MODE=confirm-other
OUT=$(run_relaunch ios default default default); RC=$?
unset FM_FAKE_RELAUNCH_MODE
expect_code 0 "$RC" "a relaunch whose host resolves a different identity should succeed"$'\n'"$OUT"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed model"
assert_no_grep 'harness=default' "$HOME_DIR/state/ios.meta" \
  "the parent record must not keep the unresolved request"
pass "a remote relaunch records the identity the host confirmed"

reset_meta
FM_FAKE_RELAUNCH_MODE=race
FM_FAKE_RACE_DIR="$TMP/relaunch-race"
mkdir -p "$FM_FAKE_RACE_DIR"
(
  FM_FAKE_SLEEP_LOG="$FM_FAKE_RACE_DIR/a-sleeps" \
    run_relaunch ios claude claude-opus-5-5 medium > "$TMP/relaunch-a.out"
  printf '%s\n' "$?" > "$TMP/relaunch-a.rc"
) &
RELAUNCH_A_PID=$!
if ! wait_for_process_path "$FM_FAKE_RACE_DIR/claude-mutated" "$RELAUNCH_A_PID"; then
  : > "$FM_FAKE_RACE_DIR/release-claude"
  wait "$RELAUNCH_A_PID"
  fail "the first concurrent relaunch did not reach the remote endpoint"
fi
(
  FM_FAKE_SLEEP_LOG="$FM_FAKE_RACE_DIR/b-sleeps" \
    run_relaunch ios pi openai-codex/gpt-5.6-sol high > "$TMP/relaunch-b.out"
  printf '%s\n' "$?" > "$TMP/relaunch-b.rc"
) &
RELAUNCH_B_PID=$!
RELAUNCH_B_WAITING=0
wait_for_process_line 0.1 "$FM_FAKE_RACE_DIR/b-sleeps" "$RELAUNCH_B_PID" \
  && RELAUNCH_B_WAITING=1
RELAUNCH_OVERLAPPED=0
[ ! -e "$FM_FAKE_RACE_DIR/pi-mutated" ] || RELAUNCH_OVERLAPPED=1
: > "$FM_FAKE_RACE_DIR/release-claude"
wait "$RELAUNCH_A_PID"
wait "$RELAUNCH_B_PID"
RELAUNCH_A_RC=$(cat "$TMP/relaunch-a.rc")
RELAUNCH_B_RC=$(cat "$TMP/relaunch-b.rc")
expect_code 0 "$RELAUNCH_A_RC" "the first concurrent relaunch should succeed"
expect_code 0 "$RELAUNCH_B_RC" "the second concurrent relaunch should succeed"
[ "$RELAUNCH_B_WAITING" -eq 1 ] \
  || fail "the second relaunch did not reach the contended metadata lock"
[ "$RELAUNCH_OVERLAPPED" -eq 0 ] \
  || fail "a second relaunch mutated the endpoint before the first published its route"
[ "$(cat "$FM_FAKE_RACE_DIR/endpoint")" = pi ] \
  || fail "the endpoint should run the last serialized relaunch"
assert_grep 'harness=pi' "$HOME_DIR/state/ios.meta" \
  "the parent route should match the last serialized relaunch"
[ ! -e "$HOME_DIR/state/.meta-ios.lock" ] \
  || fail "the relaunch metadata lock should be released"
unset FM_FAKE_RELAUNCH_MODE FM_FAKE_RACE_DIR
pass "concurrent remote relaunches keep the endpoint and parent route aligned"

# --- a refused relaunch leaves the parent's record untouched -----------------
reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-refusal.meta"
FM_FAKE_RELAUNCH_MODE=refuse
OUT=$(run_relaunch ios notaharness - -); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a refused host relaunch must not be reported as successful"
assert_contains "$OUT" "unverified remote secondmate harness" \
  "the refusal reason should reach the caller"
cmp -s "$TMP/ios-before-refusal.meta" "$HOME_DIR/state/ios.meta" \
  || fail "a refused relaunch must not touch the parent's record"
pass "a refused remote relaunch leaves the parent's record untouched"

# --- a local (non-remote) secondmate is refused, not silently mishandled ----
fm_write_meta "$HOME_DIR/state/local1.meta" \
  "window=firstmate:fm-local1" "endpoint_task_id=local1" \
  "worktree=/srv/local1" "project=/srv/local1" "harness=codex" \
  "kind=secondmate" "mode=secondmate" "yolo=off" "home=/srv/local1"
OUT=$(run_relaunch local1 claude - -); RC=$?
[ "$RC" -ne 0 ] || fail "a local secondmate must not be accepted by the remote relaunch tool"
assert_contains "$OUT" "not a remotely placed secondmate" \
  "the refusal should explain the tool this task needs instead"
pass "a local secondmate is refused by the remote relaunch tool"

# --- a relaunch keeps an already-armed PR poll authenticating ---------------
# fm-pr-check.sh now refuses to arm a poll on a kind=secondmate record, but a
# record armed before that refusal can still carry the block until the
# watcher retires it. fm-pr-check.sh wrote pr= (and, when a forge head was
# readable, pr_head=) as the LAST lines of the record, and
# fm_pr_metadata_identity_parse treats any other key appearing after pr= as
# invalid, so this wrapper must not append its harness=/model=/effort= lines
# after that identity block. The fixture is seeded the way such a record was
# really written: pr= appended last to the meta, then the poll artifacts
# published through the same fm_pr_poll_prepare/fm_pr_poll_publish_prepared
# pair fm-pr-check.sh uses, since the refused entry point cannot arm it.
reset_meta
printf 'pr=https://github.com/example/repo/pull/1\n' >> "$HOME_DIR/state/ios.meta" \
  || fail "could not write the pr= identity for the relaunch-ordering test"
fm_pr_poll_prepare "$HOME_DIR/state" ios github \
  https://github.com/example/repo/pull/1 github.com example/repo 1 \
  "$ROOT/bin/fm-pr-poll.sh" \
  || fail "could not prepare the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_publish_prepared \
  || fail "could not publish the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "PR poll fixture did not authenticate before the relaunch"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed with an armed PR poll"$'\n'"$OUT"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "a remote relaunch broke PR poll authentication by writing harness/model/effort after pr="
pass "a remote relaunch keeps an already-armed PR poll authenticating"

echo "ALL TESTS PASSED"
