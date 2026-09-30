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
  || { echo "skip: sqlite3 is required to fake the no-mistakes daemon state"; exit 0; }
command -v python3 >/dev/null 2>&1 \
  || { echo "skip: python3 is required to read the daemon state and take the slot lock"; exit 0; }

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

# seed_db <kind>:<count>...: rebuild the fake daemon store from run shapes.
#   executing  live run working a non-ci step                   counts
#   between    live run whose steps all sit pending between steps  counts
#   queued     registered run the daemon has not picked up yet   counts
#   cimix      live run running ci and a non-ci step together    counts
#   parked     live run waiting on its agent at a gate           holds no slot
#   ci         live run whose only executing step is the ci monitor holds no slot
#   cifix      live run whose ci step has moved on to a fix round   counts
#   fixing     live run whose non-ci step has moved on to a fix round   counts
#   terminal   finished run                                      holds no slot
#   unknown    live run carrying a status word this repo does not classify  counts
seed_db() {
  local spec kind n i runs='' steps=''
  rm -f "$DB"
  for spec in "$@"; do
    kind=${spec%%:*}
    n=${spec#*:}
    for ((i = 1; i <= n; i++)); do
      case $kind in
        executing)
          runs+="${runs:+,}('exec-$i','running',NULL)"
          steps+="${steps:+,}('exec-$i','review','running')"
          ;;
        between)
          runs+="${runs:+,}('between-$i','running',NULL)"
          steps+="${steps:+,}('between-$i','review','completed'),('between-$i','test','pending')"
          ;;
        queued)
          runs+="${runs:+,}('queued-$i','pending',NULL)"
          steps+="${steps:+,}('queued-$i','review','pending')"
          ;;
        cimix)
          runs+="${runs:+,}('cimix-$i','running',NULL)"
          steps+="${steps:+,}('cimix-$i','ci','running'),('cimix-$i','test','running')"
          ;;
        parked)
          runs+="${runs:+,}('parked-$i','running',1790676506)"
          steps+="${steps:+,}('parked-$i','review','fixing')"
          ;;
        ci)
          runs+="${runs:+,}('ci-$i','running',NULL)"
          steps+="${steps:+,}('ci-$i','review','completed'),('ci-$i','ci','running')"
          ;;
        cifix)
          runs+="${runs:+,}('cifix-$i','running',NULL)"
          steps+="${steps:+,}('cifix-$i','review','completed'),('cifix-$i','ci','fixing')"
          ;;
        fixing)
          runs+="${runs:+,}('fixing-$i','running',NULL)"
          steps+="${steps:+,}('fixing-$i','review','fixing')"
          ;;
        terminal)
          runs+="${runs:+,}('done-$i','completed',NULL)"
          steps+="${steps:+,}('done-$i','review','completed')"
          ;;
        unknown)
          runs+="${runs:+,}('unknown-$i','quiescing',NULL)"
          steps+="${steps:+,}('unknown-$i','review','running')"
          ;;
        *) fail "unknown seed kind '$kind'" ;;
      esac
    done
  done
  sqlite3 "$DB" "
    CREATE TABLE runs (id TEXT, status TEXT, awaiting_agent_since INTEGER);
    CREATE TABLE step_results (run_id TEXT, step_name TEXT, status TEXT);
    ${runs:+INSERT INTO runs VALUES $runs;}
    ${steps:+INSERT INTO step_results VALUES $steps;}"
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
seed_db executing:2 terminal:4
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] || fail "below the default limit should admit, got $RUN_STATUS: $RUN_ERR"
[ -z "$RUN_ERR" ] || fail "an admitted start should stay silent on stderr, got: $RUN_ERR"
printf '%s' "$RUN_OUT" | grep -q 'marker-from-command' \
  || fail "the wrapped command's stdout should pass through, got: $RUN_OUT"
[ ! -e "$LIMIT_FILE" ] || fail "an admitted start must not materialize a limit file"

# --- at the limit the caller must wait, and the start must not run -----------

: > "$START_LOG"
seed_db executing:3 terminal:1
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] || fail "at the limit should exit $WAIT_CODE, got $RUN_STATUS"
[ "$(started_count)" -eq 0 ] || fail "a refused caller must not run the wrapped start"
printf '%s' "$RUN_ERR" | grep -q '3 counted' || fail "wait reason must name the count, got: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -q 'limit 3' || fail "wait reason must name the limit, got: $RUN_ERR"
for held in exec-1 exec-2 exec-3; do
  printf '%s' "$RUN_ERR" | grep -q "$held" \
    || fail "wait reason must name the counted run ids so an operator can clear them, got: $RUN_ERR"
done
! printf '%s' "$RUN_ERR" | grep -q 'done-1' \
  || fail "wait reason must name only the counted runs, got: $RUN_ERR"

# --- parked and ci-monitoring runs hold no slot ------------------------------

seed_db executing:1 parked:5 ci:4 terminal:2
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] \
  || fail "parked and ci-monitoring runs must not count toward the cap, got $RUN_STATUS: $RUN_ERR"

# --- a ci fix round is work, not a monitor, and holds its slot ---------------
# The ship brief drives workers into this state with `axi respond --action fix`
# after CI fails: the run has no other executing step, but a fixer agent runs.

seed_db cifix:3
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
  || fail "runs whose ci step is fixing must count toward the cap, got $RUN_STATUS: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -q 'cifix-1' \
  || fail "the wait reason must name the counted ci fix rounds, got: $RUN_ERR"

# --- a live non-ci fix round is work, not a wait, and holds its slot ----------
# `axi respond --action fix` at a review gate moves the review step to
# `fixing` while the run stays live: a fixer agent works, so the slot holds.

seed_db fixing:3
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
  || fail "a live run whose non-ci step is fixing must count toward the cap, got $RUN_STATUS: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -q 'fixing-1' \
  || fail "the wait reason must name the counted non-ci fix rounds, got: $RUN_ERR"

# --- a queued run counts, so a just-registered start is not double-admitted --

seed_db queued:3
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
  || fail "three queued runs should reach the default limit, got $RUN_STATUS: $RUN_ERR"

# --- a run between steps still holds its slot --------------------------------

seed_db between:3
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
  || fail "runs sitting between steps must keep counting, got $RUN_STATUS: $RUN_ERR"

# --- a ci wait alongside a live non-ci step still holds its slot -------------

seed_db cimix:3
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
  || fail "a run working a non-ci step beside its ci wait must count, got $RUN_STATUS: $RUN_ERR"

# --- an unrecognised status word holds a slot rather than vanishing ----------

seed_db unknown:3
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
  || fail "a status word the repo does not classify must still count, got $RUN_STATUS: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -q 'unknown-1' \
  || fail "wait reason must name the unclassified runs holding slots, got: $RUN_ERR"

# --- a limit-file override is honored ---------------------------------------

printf '5\n' > "$LIMIT_FILE"
seed_db executing:3
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] || fail "override raising the limit to 5 should admit 3 executing, got $RUN_STATUS: $RUN_ERR"

printf '1\n' > "$LIMIT_FILE"
seed_db executing:1 terminal:9
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] || fail "override lowering the limit to 1 should wait, got $RUN_STATUS"
printf '%s' "$RUN_ERR" | grep -q 'limit 1' || fail "wait reason must name the overridden limit, got: $RUN_ERR"

# --- invalid limit content refuses instead of falling back -------------------

for bad in '' 'abc' '0' '-2' '3 3' '0x3'; do
  printf '%s\n' "$bad" > "$LIMIT_FILE"
  seed_db terminal:1
  run_slot "$FAKE_START"
  [ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] || fail "invalid limit '$bad' should refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"
  printf '%s' "$RUN_ERR" | grep -qF "$LIMIT_FILE" \
    || fail "refusal must name the limit file, got: $RUN_ERR"
done

# --- an unreadable daemon count refuses with the exact error -----------------

clear_limit_file
seed_db terminal:1
mv "$DB" "$DB.bak"
: > "$START_LOG"
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] \
  || fail "a store no daemon has created yet records no run and must admit, got $RUN_STATUS: $RUN_ERR"
[ "$(started_count)" -eq 1 ] \
  || fail "the wrapped start must run when the store is absent, ran $(started_count) times"

printf 'this is not a sqlite database\n' > "$DB"
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] || fail "garbage daemon store should refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"
[ -n "$RUN_ERR" ] || fail "garbage daemon store refusal must carry the exact error"

# --- reader stderr noise is never parsed as a run ----------------------------
# A python3 launcher that warns on stderr (a mise shim on this host does) must
# not conjure phantom counted runs out of its own noise.

NOISY_BIN="$ENV_ROOT/noisy-bin"
mkdir -p "$NOISY_BIN"
REAL_PYTHON3="$(command -v python3)" || fail "python3 is required to exercise the daemon reader"
cat > "$NOISY_BIN/python3" <<EOF
#!/usr/bin/env bash
echo 'mise WARN no version set for python' >&2
exec '$REAL_PYTHON3' "\$@"
EOF
chmod +x "$NOISY_BIN/python3"

printf '1\n' > "$LIMIT_FILE"
CLEAN_PATH=$PATH
PATH="$NOISY_BIN:$PATH"
seed_db terminal:2
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] \
  || fail "reader stderr must not be counted as a run, got $RUN_STATUS: $RUN_ERR"

seed_db executing:1
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
  || fail "a real run must still count when the reader warns on stderr, got $RUN_STATUS: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -q 'exec-1' \
  || fail "wait reason must name the real counted run, got: $RUN_ERR"
WAIT_LINE=$(printf '%s\n' "$RUN_ERR" | grep '^wait: ') \
  || fail "the wait message must survive a noisy reader, got: $RUN_ERR"
! printf '%s' "$WAIT_LINE" | grep -q 'mise WARN' \
  || fail "reader stderr must not reach the wait message, got: $WAIT_LINE"
PATH=$CLEAN_PATH
clear_limit_file

# --- a call without a command refuses rather than claiming an advisory slot ---

seed_db terminal:1
run_slot
[ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] || fail "a bare call should refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"

# --- two concurrent callers at limit-1 admit exactly one ---------------------

REGISTERING_START="$ENV_ROOT/registering-start"
cat > "$REGISTERING_START" <<EOF
#!/usr/bin/env bash
sqlite3 '$DB' "INSERT INTO runs VALUES ('new-start','running',NULL);
  INSERT INTO step_results VALUES ('new-start','review','running');"
echo started >> '$START_LOG'
EOF
chmod +x "$REGISTERING_START"

seed_db executing:2 terminal:1
: > "$START_LOG"
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
  seed_db executing:1
  FAKE_FAIL="$ENV_ROOT/fake-fail"
  printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$FAKE_FAIL"
  chmod +x "$FAKE_FAIL"
  run_slot "$FAKE_FAIL"
  [ "$RUN_STATUS" -eq "$code" ] \
    || fail "a wrapped command exiting $code must surface as $code, got $RUN_STATUS"
done

# --- the gate's own failure modes on the one lock path -----------------------

# An unopenable lock file must refuse, not surface a python traceback as the
# start command's own failure.
UNUSABLE_LOCK="$ENV_ROOT/unusable-runtime"
mkdir -p "$UNUSABLE_LOCK/firstmate/nm-validation-slot.lock"
seed_db executing:1
RUN_OUT=$(XDG_RUNTIME_DIR="$UNUSABLE_LOCK" "$SLOT" "$FAKE_START" 2>"$ERR_FILE")
RUN_STATUS=$?
RUN_ERR=$(cat "$ERR_FILE")
[ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] \
  || fail "an unopenable slot lock must refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"
[ "$(printf '%s' "$RUN_ERR" | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "the lock refusal must be one line, got: $RUN_ERR"

# The locked descriptor must not reach the started command, which would hold
# the host slot for as long as the start's own children live.
FD_PROBE="$ENV_ROOT/fd-probe"
cat > "$FD_PROBE" <<'PROBE'
#!/usr/bin/env bash
if { true >&9; } 2>/dev/null; then echo 'lock-fd=[open]'; else echo 'lock-fd=[closed]'; fi
PROBE
chmod +x "$FD_PROBE"
seed_db executing:1
run_slot "$FD_PROBE"
[ "$RUN_STATUS" -eq 0 ] || fail "the fd probe should run, got $RUN_STATUS: $RUN_ERR"
printf '%s' "$RUN_OUT" | grep -qF 'lock-fd=[closed]' \
  || fail "the slot lock fd must not leak into the started command, got: $RUN_OUT"

seed_db executing:1
run_slot "$ENV_ROOT/no-such-start-command"
[ "$RUN_STATUS" -eq 127 ] \
  || fail "an unexecutable start must surface as 127, got $RUN_STATUS: $RUN_ERR"

# --- a signal during the wrapped start leaves no reader temp file ------------
# The wrapped start runs in the foreground, so a signal takes effect when that
# bounded start returns; what the gate owes either way is its own exit status
# and a cleaned-up reader temp file, which an untrapped signal would leak.

SLOW_START="$ENV_ROOT/slow-start"
SLOW_RUNNING="$ENV_ROOT/slow-start-running"
cat > "$SLOW_START" <<SLOW
#!/usr/bin/env bash
: > '$SLOW_RUNNING'
sleep 2
SLOW
chmod +x "$SLOW_START"

# assert_signal_cleans_up <signal> <expected status>: signal the gate only once
# its wrapped start is provably running, then require the gate's own signal
# status and no leftover reader temp file.
assert_signal_cleans_up() {
  local signal=$1 expect=$2 pid status running=0
  seed_db executing:1
  rm -f "$SLOW_RUNNING"
  python3 -c '
import os
import signal
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
' "$SLOT" "$SLOW_START" >/dev/null 2>"$ENV_ROOT/signal-err" &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$SLOW_RUNNING" ] && { running=1; break; }
    sleep 0.25
  done
  [ "$running" -eq 1 ] || fail "$signal: the wrapped start never began"
  kill -"$signal" "$pid" || fail "$signal: the gate exited before it could be signalled"
  wait "$pid"; status=$?
  [ "$status" -eq "$expect" ] \
    || fail "$signal during the wrapped start must exit $expect, got $status"
  [ -z "$(ls "$XDG_RUNTIME_DIR/firstmate"/nm-slot-reader.* 2>/dev/null)" ] \
    || fail "$signal: the reader temp file must not survive a signalled gate"
}

assert_signal_cleans_up TERM 143
assert_signal_cleans_up INT 130
assert_signal_cleans_up HUP 129

# --- the ship briefs route their start through this wrapper ------------------
# The rendered brief is the generated agent-facing interface that applies the
# cap; nothing else wires the two together.

# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
for forge in '' gerrit; do
  BRIEF=$(fm_dod_block no-mistakes slot-brief-task fm/slot-brief-task "$ENV_ROOT/data" $forge) \
    || fail "rendering the ${forge:-default} ship brief failed"
  START_LINE=$(printf '%s\n' "$BRIEF" | grep -F 'no-mistakes axi run --intent' | grep -F 'fm-nm-slot.sh') \
    || fail "the ${forge:-default} ship brief must start the run through fm-nm-slot.sh, got: $BRIEF"
  if [ "$forge" = gerrit ]; then
    printf '%s' "$START_LINE" | grep -qF -- '--skip push,pr,ci' \
      || fail "the gerrit ship brief's slot start line must keep --skip push,pr,ci, got: $START_LINE"
  else
    ! printf '%s' "$START_LINE" | grep -qF -- '--skip' \
      || fail "the default ship brief's slot start line must not skip steps, got: $START_LINE"
  fi
done

# --- --help describes the contract -------------------------------------------

run_slot --help
[ "$RUN_STATUS" -eq 0 ] || fail "--help should exit 0, got $RUN_STATUS"
printf '%s' "$RUN_OUT" | grep -q 'no-mistakes' || fail "--help should name the subject, got: $RUN_OUT"
printf '%s' "$RUN_OUT" | grep -qF 'default of 3' \
  || fail "--help should state the exact default limit of 3, got: $RUN_OUT"

pass "fm-nm-slot admits, waits, refuses, and serializes starts per contract"
