#!/usr/bin/env bash
# Live Herdr steering-doorbell slow-echo guard (live-harness-optin family).
#
# On a loaded host Claude Code can echo a typed doorbell well after the submit
# settle. The pre-Enter proof then read an empty composer, refused, and its
# clear stopped at the first empty read: one Ctrl+U deleted only the last
# wrapped row once Claude caught up, stranding the doorbell's head. Every later
# ring read that head as foreign pending text and skipped, so the steer was
# never read. A stub cannot reproduce the late echo, so this guard launches real
# Claude Code in an isolated Herdr lab and slows it by pinning it to one CPU
# beside busy loops (no signals: SIGSTOP corrupts Claude's terminal input).
#
# It requires a slowed ring to deliver, a slowed ring with no proof budget to
# leave the composer clean rather than holding a head, the next ring to
# deliver, and a stranded doorbell head to be submitted by the ring. Delivery
# means the worker moved the record into handled/. It fails naming the harness
# and version rather than degrading quietly.
#
# Run explicitly with FM_HERDR_DOORBELL_SLOW_ECHO_LIVE=1 after a Herdr or
# Claude upgrade. It needs a Linux taskset and at least two CPUs.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_DOORBELL_SLOW_ECHO_LIVE herdr jq claude stty taskset renice

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_DOORBELL_SLOW_ECHO_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-doorbell-slow-echo)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-doorbell-slow-echo.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
STATE="$TMP_ROOT/state"
TASK=slowecho
mkdir -p "$FAKEBIN" "$STATE"
CLAUDE_PID=
CLAUDE_AFFINITY=
HOGS=()

unslow() {
  [ "${#HOGS[@]}" -eq 0 ] || { kill "${HOGS[@]}" 2>/dev/null; wait "${HOGS[@]}" 2>/dev/null; }
  HOGS=()
  [ -z "$CLAUDE_AFFINITY" ] || taskset -a -p -c "$CLAUDE_AFFINITY" "$CLAUDE_PID" >/dev/null 2>&1 || true
}

cleanup() {
  local rc=$?
  trap - EXIT
  unslow
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_source herdr || fail "could not load the Herdr adapter"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$TMP_ROOT" --label fm-slowecho --no-focus) \
  || fail "could not create the isolated slow-echo workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
INBOX=$(fm_task_inbox_dir "$STATE" "$TASK")
printf 'backend=herdr\nharness=claude\n' > "$STATE/$TASK.meta"

# 51 columns wraps the doorbell over several composer rows, the incident shape.
lab pane run "$PANE" "stty cols 51 && FM_TASK_INBOX='$INBOX' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

wait_idle() {  # <seconds>
  local i=0 screen st trusted=0
  while [ "$i" -lt "$1" ]; do
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    case "$screen" in
      *'bypass permissions on'*)
        st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
        case "$st" in idle|done) return 0 ;; esac
        ;;
      *'Yes, I trust this folder'*)
        # The prompt preselects "No, exit"; a bare Enter quits Claude.
        if [ "$trusted" = 0 ]; then
          trusted=1
          lab pane send-keys "$PANE" down enter >/dev/null \
            || fail "could not accept Claude's folder-trust prompt"
        fi
        ;;
      *'claude --dangerously-skip-permissions'*)
        # A shell that treats herdr's pane run as a bracketed paste needs Enter.
        lab pane send-keys "$PANE" enter >/dev/null || true
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

wait_idle 60 || fail "Claude Code ($VERSION) on $HERDR_VER never rendered an idle composer in the lab pane"

CLAUDE_PID=$(lab pane process-info --pane "$PANE" 2>/dev/null | jq -er \
  '[.result.process_info.foreground_processes[] | select(.name == "claude") | .pid][0] | select(type == "number") | floor') \
  || fail "could not find the lab pane's Claude Code process"

affinity=$(taskset -p -c "$CLAUDE_PID") || fail "could not read Claude Code's CPU affinity"
affinity=${affinity##*: }
[[ "$affinity" =~ ^[0-9]+([,-][0-9]+)*$ ]] || fail "could not parse Claude Code's CPU affinity"
case "$affinity" in
  *[,-]*) ;;
  *) fail "FM_HERDR_DOORBELL_SLOW_ECHO_LIVE=1 needs at least two allowed CPUs to slow Claude on one of them" ;;
esac
CLAUDE_AFFINITY=$affinity

# slow <seconds>: pin Claude to the last CPU at nice 19 beside busy loops.
slow() {
  local cpu=${CLAUDE_AFFINITY##*,} t _
  cpu=${cpu##*-}
  taskset -a -p -c "$cpu" "$CLAUDE_PID" >/dev/null || fail "could not pin Claude Code to one CPU"
  for t in /proc/"$CLAUDE_PID"/task/*; do renice -n 19 -p "${t##*/}" >/dev/null 2>&1 || true; done
  for _ in 1 2 3 4; do
    taskset -c "$cpu" bash -c 'while :; do :; done' &
    HOGS+=("$!")
  done
  ( sleep "$1"; kill "${HOGS[@]}" 2>/dev/null ) &
}

# ring_new <tag> [proof-polls]: write a record asking for a marker file, then ring it.
ring_new() {
  local tag=$1 rc=0
  REC=$(fm_task_inbox_write "$STATE" "$TASK" "Run exactly: touch $TMP_ROOT/acted-$tag - then mv this message into handled/. Reply with one short line.") \
    || fail "could not write the $tag steering record"
  FM_BACKEND_HERDR_PROOF_POLLS=${2:-${FM_BACKEND_HERDR_PROOF_POLLS:-20}} fm_task_inbox_ring herdr "$TARGET" "$REC" || rc=$?
  RING_RC=$rc
}

delivered() {  # <record> <tag>
  local i=0
  while [ "$i" -lt 120 ]; do
    [ -e "$1" ] || { [ -e "$TMP_ROOT/acted-$2" ] && return 0; }
    i=$((i + 1))
    sleep 1
  done
  return 1
}

settled() {
  unslow
  wait_idle 120 || fail "Claude Code ($VERSION) on $HERDR_VER did not return to an idle composer"
}

# 1. A slowed echo is waited for and submitted.
slow 4
ring_new slow
[ "$RING_RC" = 0 ] || fail "Claude Code ($VERSION) on $HERDR_VER: a ring into a slowed echo must submit, got rc $RING_RC"
delivered "$REC" slow || fail "Claude Code ($VERSION) on $HERDR_VER: a slowed ring reported rc 0 but the record was never handled"
settled
pass "live Herdr doorbell: Claude Code ($VERSION) on $HERDR_VER submits a doorbell whose echo arrives after the settle"

# 2. With no proof budget the same late echo is refused; the composer must end
# empty, never holding the doorbell's head, and the next ring must deliver.
slow 4
ring_new cleared 0
[ "$RING_RC" = 2 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: slowing Claude did not delay its echo past the settle (ring rc $RING_RC), so the clear path went unexercised"
sleep 6
unslow
sleep 2
state=$(fm_backend_herdr_composer_state "$TARGET")
[ "$state" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a refused late echo left the composer '$state' holding: $(fm_backend_herdr_composer_content "$TARGET")"
rc=0
fm_task_inbox_ring herdr "$TARGET" "$REC" || rc=$?
[ "$rc" = 0 ] || fail "Claude Code ($VERSION) on $HERDR_VER: the ring after a cleared late echo must submit, got rc $rc"
delivered "$REC" cleared || fail "Claude Code ($VERSION) on $HERDR_VER: the re-ring after a cleared late echo was never handled"
settled
pass "live Herdr doorbell: Claude Code ($VERSION) on $HERDR_VER clears a refused late echo completely and the next ring delivers"

# 3. A doorbell head already stranded in the composer is submitted, not skipped.
REC=$(fm_task_inbox_write "$STATE" "$TASK" "Run exactly: touch $TMP_ROOT/acted-head - then mv this message into handled/. Reply with one short line.") \
  || fail "could not write the head steering record"
line=$(fm_task_inbox_doorbell_line "$REC")
fm_backend_herdr_send_literal "$TARGET" "${line:0:100}" || fail "could not stage a stranded doorbell head"
sleep 1
rc=0
fm_task_inbox_ring herdr "$TARGET" "$REC" || rc=$?
[ "$rc" = 0 ] || fail "Claude Code ($VERSION) on $HERDR_VER: a stranded doorbell head must be submitted, got rc $rc"
delivered "$REC" head || fail "Claude Code ($VERSION) on $HERDR_VER: a submitted doorbell head was never acted on"
pass "live Herdr doorbell: Claude Code ($VERSION) on $HERDR_VER submits a stranded doorbell head instead of skipping it"
