#!/usr/bin/env bash
# Contract: bin/fm-nm-slot.sh admits a no-mistakes run start only while the
# host's active-run count stays below the per-host limit, reading that count
# from the daemon's own state store and holding one host-wide lock across the
# count-then-start window, so two concurrent callers cannot both squeeze in.
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

ENV_ROOT="$(fm_test_tmproot fm-nm-slot)" || fail "cannot create test temp root"
NM_HOME="$ENV_ROOT/nmhome"
XDG_RUNTIME_DIR="$ENV_ROOT/runtime"
XDG_CONFIG_HOME="$ENV_ROOT/config"
LIMIT_FILE="$XDG_CONFIG_HOME/firstmate/nm-max-concurrent-validations"
DB="$NM_HOME/state.sqlite"
ERR_FILE="$ENV_ROOT/slot-stderr"
mkdir -p "$NM_HOME" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/firstmate"
export NM_HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME

# seed_db <active> <terminal>: rebuild the fake daemon store with <active>
# rows in an active status (the daemon's own pending/running pair) and
# <terminal> rows in a terminal status that must never count.
seed_db() {
  local active=$1 terminal=$2 values='' i
  for ((i = 1; i <= active; i++)); do values+="${values:+,}('active-$i','running')"; done
  for ((i = 1; i <= terminal; i++)); do values+="${values:+,}('done-$i','completed')"; done
  rm -f "$DB"
  if [ -n "$values" ]; then
    sqlite3 "$DB" "CREATE TABLE runs (id TEXT, status TEXT); INSERT INTO runs VALUES $values;"
  else
    sqlite3 "$DB" "CREATE TABLE runs (id TEXT, status TEXT);"
  fi
}

clear_limit_file() {
  rm -f "$LIMIT_FILE"
}

# run_slot <args...>: capture exit status, stdout, and stderr of one call.
run_slot() {
  RUN_OUT=$("$SLOT" "$@" 2>"$ERR_FILE")
  RUN_STATUS=$?
  RUN_ERR=$(cat "$ERR_FILE")
}

# --- absent config means the default of 3, and below-limit admits -----------

clear_limit_file
seed_db 2 4
run_slot
[ "$RUN_STATUS" -eq 0 ] || fail "below the default limit should exit 0, got $RUN_STATUS: $RUN_ERR"
[ -z "$RUN_ERR" ] || fail "an admitted check should stay silent on stderr, got: $RUN_ERR"
[ ! -e "$LIMIT_FILE" ] || fail "an admitted check must not materialize a limit file"

# --- at the limit the caller must wait --------------------------------------

seed_db 3 1
run_slot
[ "$RUN_STATUS" -eq 1 ] || fail "at the limit should exit 1, got $RUN_STATUS"
printf '%s' "$RUN_ERR" | grep -q '3 active' || fail "wait reason must name the count, got: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -q 'limit 3' || fail "wait reason must name the limit, got: $RUN_ERR"

# --- a limit-file override is honored ---------------------------------------

printf '5\n' > "$LIMIT_FILE"
seed_db 3 0
run_slot
[ "$RUN_STATUS" -eq 0 ] || fail "override raising the limit to 5 should admit 3 active, got $RUN_STATUS: $RUN_ERR"

printf '1\n' > "$LIMIT_FILE"
seed_db 1 9
run_slot
[ "$RUN_STATUS" -eq 1 ] || fail "override lowering the limit to 1 should wait on 1 active, got $RUN_STATUS"
printf '%s' "$RUN_ERR" | grep -q 'limit 1' || fail "wait reason must name the overridden limit, got: $RUN_ERR"

# --- invalid limit content refuses instead of falling back -------------------

for bad in '' 'abc' '0' '-2' '3 3' '0x3'; do
  printf '%s\n' "$bad" > "$LIMIT_FILE"
  seed_db 0 0
  run_slot
  [ "$RUN_STATUS" -eq 2 ] || fail "invalid limit '$bad' should refuse with exit 2, got $RUN_STATUS: $RUN_ERR"
  printf '%s' "$RUN_ERR" | grep -qF "$LIMIT_FILE" \
    || fail "refusal must name the limit file, got: $RUN_ERR"
done

# --- an unreadable daemon count refuses with the exact error -----------------

clear_limit_file
seed_db 0 0
mv "$DB" "$DB.bak"
run_slot
[ "$RUN_STATUS" -eq 2 ] || fail "missing daemon store should refuse with exit 2, got $RUN_STATUS: $RUN_ERR"
printf '%s' "$RUN_ERR" | grep -qF "$DB" || fail "refusal must name the store path, got: $RUN_ERR"

printf 'this is not a sqlite database\n' > "$DB"
run_slot
[ "$RUN_STATUS" -eq 2 ] || fail "garbage daemon store should refuse with exit 2, got $RUN_STATUS: $RUN_ERR"
[ -n "$RUN_ERR" ] || fail "garbage daemon store refusal must carry the exact error"

# --- two concurrent callers at limit-1 admit exactly one ---------------------

seed_db 2 1
START_LOG="$ENV_ROOT/start.log"
: > "$START_LOG"
FAKE_START="$ENV_ROOT/fake-start"
cat > "$FAKE_START" <<EOF
#!/usr/bin/env bash
sqlite3 '$DB' "INSERT INTO runs VALUES ('new-start', 'running');"
echo started >> '$START_LOG'
EOF
chmod +x "$FAKE_START"
"$SLOT" "$FAKE_START" >"$ENV_ROOT/c1-out" 2>"$ENV_ROOT/c1-err" &
PID1=$!
"$SLOT" "$FAKE_START" >"$ENV_ROOT/c2-out" 2>"$ENV_ROOT/c2-err" &
PID2=$!
wait "$PID1"; STATUS1=$?
wait "$PID2"; STATUS2=$?
ADMITTED=0
WAITED=0
[ "$STATUS1" -eq 0 ] && ADMITTED=$((ADMITTED + 1))
[ "$STATUS2" -eq 0 ] && ADMITTED=$((ADMITTED + 1))
[ "$STATUS1" -eq 1 ] && WAITED=$((WAITED + 1))
[ "$STATUS2" -eq 1 ] && WAITED=$((WAITED + 1))
[ "$ADMITTED" -eq 1 ] || fail "exactly one concurrent caller should be admitted, got $ADMITTED (statuses $STATUS1/$STATUS2)"
[ "$WAITED" -eq 1 ] || fail "exactly one concurrent caller should wait, got $WAITED (statuses $STATUS1/$STATUS2)"
[ "$(wc -l < "$START_LOG")" -eq 1 ] || fail "the wrapped start must run exactly once, ran $(wc -l < "$START_LOG") times"

# --- an admitted wrapped command runs with stdout and status passed through --

seed_db 1 0
FAKE_ECHO="$ENV_ROOT/fake-echo"
printf '#!/usr/bin/env bash\necho marker-from-command\nexit 7\n' > "$FAKE_ECHO"
chmod +x "$FAKE_ECHO"
run_slot "$FAKE_ECHO"
[ "$RUN_STATUS" -eq 7 ] || fail "a wrapped command's exit status should pass through, got $RUN_STATUS"
printf '%s' "$RUN_OUT" | grep -q 'marker-from-command' \
  || fail "a wrapped command's stdout should pass through, got: $RUN_OUT"

# --- --help describes the contract -------------------------------------------

run_slot --help
[ "$RUN_STATUS" -eq 0 ] || fail "--help should exit 0, got $RUN_STATUS"
printf '%s' "$RUN_OUT" | grep -q 'no-mistakes' || fail "--help should name the subject, got: $RUN_OUT"
printf '%s' "$RUN_OUT" | grep -q '3' || fail "--help should name the default limit, got: $RUN_OUT"

pass "fm-nm-slot admits, waits, refuses, and serializes starts per contract"
