#!/usr/bin/env bash
# Contract: bin/fm-nm-slot.sh admits a no-mistakes run start only while the
# host's executing-run count stays below the per-host limit, reading that count
# from the daemon's own state store and holding one host-wide lock across the
# count-then-start window, so two concurrent callers cannot both squeeze in.
# Its own wait and refusal codes (75, 78) stay outside the range the wrapped
# start command uses, so a failed start is never read as a full slot.
#
# The suite drives the script through its CLI against a faked daemon: a
# crafted state.sqlite under a temp NM_HOME, a temp XDG_CONFIG_HOME for the
# limit file, and a temp XDG_RUNTIME_DIR for the slot lock, so no case here
# touches the real daemon, the real limit file, or the real host slot.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sqlite3 >/dev/null 2>&1 \
  || fail "sqlite3 is required to fake the no-mistakes daemon state"
command -v flock >/dev/null 2>&1 \
  || fail "flock is required to exercise the slot mutex"

SLOT="$ROOT/bin/fm-nm-slot.sh"
WAIT_CODE=75
REFUSAL_CODE=78

ENV_ROOT="$(fm_test_tmproot fm-nm-slot)" || fail "cannot create test temp root"
NM_HOME="$ENV_ROOT/nmhome"
XDG_RUNTIME_DIR="$ENV_ROOT/runtime"
XDG_CONFIG_HOME="$ENV_ROOT/config"
LIMIT_FILE="$XDG_CONFIG_HOME/firstmate/nm-max-concurrent-validations"
DB="$NM_HOME/state.sqlite"
ERR_FILE="$ENV_ROOT/slot-stderr"
mkdir -p "$NM_HOME" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/firstmate"
export NM_HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME

# seed_db <executing> <parked> <ci> <terminal>: rebuild the fake daemon store
# with <executing> live runs working a non-ci step (the only shape that holds
# a slot), <parked> live runs waiting on their agent at a gate, <ci> live runs
# whose only executing step is the forge CI wait, and <terminal> finished
# runs. Only the first group may count.
seed_db() {
  local executing=$1 parked=$2 ci=$3 terminal=$4 runs='' steps='' i
  for ((i = 1; i <= executing; i++)); do
    runs+="${runs:+,}('exec-$i','running',NULL)"
    steps+="${steps:+,}('exec-$i','review','running')"
  done
  for ((i = 1; i <= parked; i++)); do
    runs+="${runs:+,}('parked-$i','running',1790676506)"
    steps+="${steps:+,}('parked-$i','review','fixing')"
  done
  for ((i = 1; i <= ci; i++)); do
    runs+="${runs:+,}('ci-$i','running',NULL)"
    steps+="${steps:+,}('ci-$i','ci','running')"
  done
  for ((i = 1; i <= terminal; i++)); do
    runs+="${runs:+,}('done-$i','completed',NULL)"
    steps+="${steps:+,}('done-$i','review','completed')"
  done
  rm -f "$DB"
  sqlite3 "$DB" "
    CREATE TABLE runs (id TEXT, status TEXT, awaiting_agent_since INTEGER);
    CREATE TABLE step_results (run_id TEXT, step_name TEXT, status TEXT);
    ${runs:+INSERT INTO runs VALUES $runs;}
    ${steps:+INSERT INTO step_results VALUES $steps;}"
}

seed_pending() {  # <count>
  local i
  seed_db 0 0 0 0
  for ((i = 1; i <= $1; i++)); do
    sqlite3 "$DB" "INSERT INTO runs VALUES ('queued-$i','pending',NULL);"
  done
}

clear_limit_file() {
  rm -f "$LIMIT_FILE"
}

START_LOG="$ENV_ROOT/start.log"
FAKE_START="$ENV_ROOT/fake-start"
cat > "$FAKE_START" <<EOF
#!/usr/bin/env bash
echo started >> '$START_LOG'
echo marker-from-command
EOF
chmod +x "$FAKE_START"
: > "$START_LOG"

# run_slot <args...>: capture exit status, stdout, and stderr of one call.
run_slot() {
  RUN_OUT=$("$SLOT" "$@" 2>"$ERR_FILE")
  RUN_STATUS=$?
  RUN_ERR=$(cat "$ERR_FILE")
}

started_count() {
  wc -l < "$START_LOG" | tr -d ' '
}

# --- absent config means the default of 3, and below-limit runs the start ----

clear_limit_file
seed_db 2 0 0 4
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] || fail "below the default limit should admit, got $RUN_STATUS: $RUN_ERR"
[ -z "$RUN_ERR" ] || fail "an admitted start should stay silent on stderr, got: $RUN_ERR"
printf '%s' "$RUN_OUT" | grep -q 'marker-from-command' \
  || fail "the wrapped command's stdout should pass through, got: $RUN_OUT"
[ ! -e "$LIMIT_FILE" ] || fail "an admitted start must not materialize a limit file"

# --- at the limit the caller must wait, and the start must not run -----------

: > "$START_LOG"
seed_db 3 0 0 1
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] || fail "at the limit should exit $WAIT_CODE, got $RUN_STATUS"
[ "$(started_count)" -eq 0 ] || fail "a refused caller must not run the wrapped start"
printf '%s' "$RUN_ERR" | grep -q '3 executing' || fail "wait reason must name the count, got: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -q 'limit 3' || fail "wait reason must name the limit, got: $RUN_ERR"

# --- parked and ci-waiting runs hold no slot ---------------------------------

seed_db 1 5 4 2
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] \
  || fail "parked and ci-waiting runs must not count toward the cap, got $RUN_STATUS: $RUN_ERR"

# --- a queued run counts, so a just-registered start is not double-admitted --

seed_pending 3
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
  || fail "three queued runs should reach the default limit, got $RUN_STATUS: $RUN_ERR"

# --- a limit-file override is honored ---------------------------------------

printf '5\n' > "$LIMIT_FILE"
seed_db 3 0 0 0
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] || fail "override raising the limit to 5 should admit 3 executing, got $RUN_STATUS: $RUN_ERR"

printf '1\n' > "$LIMIT_FILE"
seed_db 1 0 0 9
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] || fail "override lowering the limit to 1 should wait, got $RUN_STATUS"
printf '%s' "$RUN_ERR" | grep -q 'limit 1' || fail "wait reason must name the overridden limit, got: $RUN_ERR"

# --- invalid limit content refuses instead of falling back -------------------

for bad in '' 'abc' '0' '-2' '3 3' '0x3'; do
  printf '%s\n' "$bad" > "$LIMIT_FILE"
  seed_db 0 0 0 0
  run_slot "$FAKE_START"
  [ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] || fail "invalid limit '$bad' should refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"
  printf '%s' "$RUN_ERR" | grep -qF "$LIMIT_FILE" \
    || fail "refusal must name the limit file, got: $RUN_ERR"
done

# --- an unreadable daemon count refuses with the exact error -----------------

clear_limit_file
seed_db 0 0 0 0
mv "$DB" "$DB.bak"
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] || fail "missing daemon store should refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -qF "$DB" || fail "refusal must name the store path, got: $RUN_ERR"

printf 'this is not a sqlite database\n' > "$DB"
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] || fail "garbage daemon store should refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"
[ -n "$RUN_ERR" ] || fail "garbage daemon store refusal must carry the exact error"

# --- a call without a command refuses rather than claiming an advisory slot ---

seed_db 0 0 0 0
run_slot
[ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] || fail "a bare call should refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"

# --- two concurrent callers at limit-1 admit exactly one ---------------------

seed_db 2 0 0 1
: > "$START_LOG"
REGISTERING_START="$ENV_ROOT/registering-start"
cat > "$REGISTERING_START" <<EOF
#!/usr/bin/env bash
sqlite3 '$DB' "INSERT INTO runs VALUES ('new-start','running',NULL);
  INSERT INTO step_results VALUES ('new-start','review','running');"
echo started >> '$START_LOG'
EOF
chmod +x "$REGISTERING_START"
"$SLOT" "$REGISTERING_START" >"$ENV_ROOT/c1-out" 2>"$ENV_ROOT/c1-err" &
PID1=$!
"$SLOT" "$REGISTERING_START" >"$ENV_ROOT/c2-out" 2>"$ENV_ROOT/c2-err" &
PID2=$!
wait "$PID1"; STATUS1=$?
wait "$PID2"; STATUS2=$?
ADMITTED=0
WAITED=0
[ "$STATUS1" -eq 0 ] && ADMITTED=$((ADMITTED + 1))
[ "$STATUS2" -eq 0 ] && ADMITTED=$((ADMITTED + 1))
[ "$STATUS1" -eq "$WAIT_CODE" ] && WAITED=$((WAITED + 1))
[ "$STATUS2" -eq "$WAIT_CODE" ] && WAITED=$((WAITED + 1))
[ "$ADMITTED" -eq 1 ] || fail "exactly one concurrent caller should be admitted, got $ADMITTED (statuses $STATUS1/$STATUS2)"
[ "$WAITED" -eq 1 ] || fail "exactly one concurrent caller should wait, got $WAITED (statuses $STATUS1/$STATUS2)"
[ "$(started_count)" -eq 1 ] || fail "the wrapped start must run exactly once, ran $(started_count) times"

# --- a wrapped command's own failure codes reach the caller unchanged --------

for code in 1 2 7; do
  seed_db 1 0 0 0
  FAKE_FAIL="$ENV_ROOT/fake-fail"
  printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$FAKE_FAIL"
  chmod +x "$FAKE_FAIL"
  run_slot "$FAKE_FAIL"
  [ "$RUN_STATUS" -eq "$code" ] \
    || fail "a wrapped command exiting $code must surface as $code, got $RUN_STATUS"
done

# --- --help describes the contract -------------------------------------------

run_slot --help
[ "$RUN_STATUS" -eq 0 ] || fail "--help should exit 0, got $RUN_STATUS"
printf '%s' "$RUN_OUT" | grep -q 'no-mistakes' || fail "--help should name the subject, got: $RUN_OUT"
printf '%s' "$RUN_OUT" | grep -q '3' || fail "--help should name the default limit, got: $RUN_OUT"

pass "fm-nm-slot admits, waits, refuses, and serializes starts per contract"
