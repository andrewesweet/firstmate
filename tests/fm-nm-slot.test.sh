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
#   ci         live run whose only executing step is the ci wait holds no slot
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

# --- parked and ci-waiting runs hold no slot ---------------------------------

seed_db executing:1 parked:5 ci:4 terminal:2
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq 0 ] \
  || fail "parked and ci-waiting runs must not count toward the cap, got $RUN_STATUS: $RUN_ERR"

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
run_slot "$FAKE_START"
[ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] || fail "missing daemon store should refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -qF "$DB" || fail "refusal must name the store path, got: $RUN_ERR"

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
! printf '%s' "$RUN_ERR" | grep -q 'mise WARN' \
  || fail "reader stderr must not reach the wait message, got: $RUN_ERR"
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

# assert_serialised <label> <PATH for the gate>: two callers race one free
# slot; the mutex must let exactly one through whichever lock implementation
# the gate's PATH leaves it.
assert_serialised() {
  local label=$1 slot_path=$2 status1 status2 admitted=0 waited=0
  seed_db executing:2 terminal:1
  : > "$START_LOG"
  PATH="$slot_path" "$SLOT" "$REGISTERING_START" >"$ENV_ROOT/c1-out" 2>"$ENV_ROOT/c1-err" &
  local pid1=$!
  PATH="$slot_path" "$SLOT" "$REGISTERING_START" >"$ENV_ROOT/c2-out" 2>"$ENV_ROOT/c2-err" &
  local pid2=$!
  wait "$pid1"; status1=$?
  wait "$pid2"; status2=$?
  [ "$status1" -eq 0 ] && admitted=$((admitted + 1))
  [ "$status2" -eq 0 ] && admitted=$((admitted + 1))
  [ "$status1" -eq "$WAIT_CODE" ] && waited=$((waited + 1))
  [ "$status2" -eq "$WAIT_CODE" ] && waited=$((waited + 1))
  [ "$admitted" -eq 1 ] || fail "$label: exactly one concurrent caller should be admitted, got $admitted (statuses $status1/$status2)"
  [ "$waited" -eq 1 ] || fail "$label: exactly one concurrent caller should wait, got $waited (statuses $status1/$status2)"
  [ "$(started_count)" -eq 1 ] || fail "$label: the wrapped start must run exactly once, ran $(started_count) times"
}

if command -v flock >/dev/null 2>&1; then
  assert_serialised "the flock lock" "$PATH"
else
  echo "skip: flock is absent, so only the python3 lock path is exercised"
fi

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

# --- a host without the flock binary keeps the same mutex --------------------
# macOS worker hosts have no flock; the gate must take the same host-wide lock
# through python3 rather than admitting an unserialised start.

NOFLOCK_BIN="$ENV_ROOT/noflock-bin"
mkdir -p "$NOFLOCK_BIN"
BOUNDING_TOOL=''
for tool in bash env python3 sqlite3 mkdir mktemp grep tail cat dirname basename rm awk timeout gtimeout perl; do
  tool_path=$(command -v "$tool") || continue
  ln -sf "$tool_path" "$NOFLOCK_BIN/$tool"
  case $tool in timeout | gtimeout | perl) BOUNDING_TOOL=${BOUNDING_TOOL:-$tool} ;; esac
done
[ ! -e "$NOFLOCK_BIN/flock" ] || fail "the flock-less PATH must not expose flock"

if [ -z "$BOUNDING_TOOL" ]; then
  echo "skip: no bounding tool (timeout, gtimeout or perl) for the flock-less lock path"
else
  # run_noflock <args...>: drive the gate with a PATH that has no flock binary.
  run_noflock() {
    RUN_OUT=$(PATH="$NOFLOCK_BIN" "$SLOT" "$@" 2>"$ERR_FILE")
    RUN_STATUS=$?
    RUN_ERR=$(cat "$ERR_FILE")
  }

  clear_limit_file
  seed_db executing:1
  run_noflock "$FAKE_START"
  [ "$RUN_STATUS" -eq 0 ] \
    || fail "a host without flock must still admit below the limit, got $RUN_STATUS: $RUN_ERR"
  [ -z "$RUN_ERR" ] \
    || fail "an admitted start on a flock-less host must stay silent on stderr, got: $RUN_ERR"

  seed_db executing:3
  run_noflock "$FAKE_START"
  [ "$RUN_STATUS" -eq "$WAIT_CODE" ] \
    || fail "a host without flock must still wait at the limit, got $RUN_STATUS: $RUN_ERR"

  assert_serialised "the python3 lock" "$NOFLOCK_BIN"

  # An unopenable lock file must refuse like the flock branch, not surface a
  # python traceback as the start command's own failure.
  UNUSABLE_LOCK="$ENV_ROOT/unusable-runtime"
  mkdir -p "$UNUSABLE_LOCK/firstmate/nm-validation-slot.lock"
  seed_db executing:1
  RUN_OUT=$(PATH="$NOFLOCK_BIN" XDG_RUNTIME_DIR="$UNUSABLE_LOCK" "$SLOT" "$FAKE_START" 2>"$ERR_FILE")
  RUN_STATUS=$?
  RUN_ERR=$(cat "$ERR_FILE")
  [ "$RUN_STATUS" -eq "$REFUSAL_CODE" ] \
    || fail "an unopenable slot lock must refuse with exit $REFUSAL_CODE, got $RUN_STATUS: $RUN_ERR"
  [ "$(printf '%s' "$RUN_ERR" | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "the lock refusal must be one line, got: $RUN_ERR"

  # The lock-held marker must not reach the started command or its children.
  MARKER_PROBE="$ENV_ROOT/marker-probe"
  cat > "$MARKER_PROBE" <<'PROBE'
#!/usr/bin/env bash
printf 'marker=[%s]\n' "${FM_NM_SLOT_LOCK_HELD:-}"
PROBE
  chmod +x "$MARKER_PROBE"
  seed_db executing:1
  run_noflock "$MARKER_PROBE"
  [ "$RUN_STATUS" -eq 0 ] || fail "the marker probe should run, got $RUN_STATUS: $RUN_ERR"
  printf '%s' "$RUN_OUT" | grep -qF 'marker=[]' \
    || fail "the lock-held marker must not leak into the started command, got: $RUN_OUT"

  # A start command that cannot be executed is the command's own failure, never
  # the gate's refusal, on either lock path.
  seed_db executing:1
  run_noflock "$ENV_ROOT/no-such-start-command"
  [ "$RUN_STATUS" -eq 127 ] \
    || fail "an unexecutable start must surface as 127 on the python3 lock path, got $RUN_STATUS: $RUN_ERR"
fi

seed_db executing:1
run_slot "$ENV_ROOT/no-such-start-command"
[ "$RUN_STATUS" -eq 127 ] \
  || fail "an unexecutable start must surface as 127, got $RUN_STATUS: $RUN_ERR"

# --- a signal during the wrapped start stops the gate ------------------------
# A supervisor that stops a worker mid-start must not get a started validation
# and a held slot back.

seed_db executing:1
SLOW_START="$ENV_ROOT/slow-start"
cat > "$SLOW_START" <<'SLOW'
#!/usr/bin/env bash
sleep 10
SLOW
chmod +x "$SLOW_START"
"$SLOT" "$SLOW_START" >/dev/null 2>"$ENV_ROOT/term-err" &
TERM_PID=$!
SIGNALLED=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.3
  kill -TERM "$TERM_PID" 2>/dev/null && { SIGNALLED=1; break; }
done
[ "$SIGNALLED" -eq 1 ] || fail "the gate exited before it could be signalled"
wait "$TERM_PID"; TERM_STATUS=$?
[ "$TERM_STATUS" -eq 143 ] \
  || fail "a TERM during the wrapped start must exit 143, got $TERM_STATUS"
[ -z "$(ls "$XDG_RUNTIME_DIR/firstmate"/nm-slot-reader.* 2>/dev/null)" ] \
  || fail "the reader temp file must not survive a signalled gate"

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
printf '%s' "$RUN_OUT" | grep -q '3' || fail "--help should name the default limit, got: $RUN_OUT"

pass "fm-nm-slot admits, waits, refuses, and serializes starts per contract"
