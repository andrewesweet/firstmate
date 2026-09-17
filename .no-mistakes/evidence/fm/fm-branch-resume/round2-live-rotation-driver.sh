#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude Code supervision-branch mod
# (.claude/mods/fm-branch-mod, docs/claude-supervision-branch.md): one real
# Claude Code primary in tmux, launched exactly as the docs page prescribes,
# supervising one stand-in task in a temporary scratch home. It proves, on the
# pinned Claude Code version only:
#   1. the module loads (enabled by state/.branch-mod-mode) and main takes the
#      home's session lock;
#   2. the first watcher wake on a routine status line passes the classifier
#      and is routed to a freshly spawned branch agent, which handles it and
#      reports a routine outcome without a main turn;
#   3. the next wake, carrying a captain-class `done:` line, is passed to main
#      by the classifier with a covering captain outcome row, main drains it,
#      and the routine wake after it reaches the same agent through
#      SendMessage;
#   4. across the run: one spawn, every send successful, no dropped hand-back,
#      no backstop delivery.
# The pin is the module's own refusal gate: on any other Claude Code version the
# test skips, because the module would refuse to load and the assertions would
# be meaningless. A pin bump is landed by running this test on the new version
# (docs/claude-supervision-branch.md "Updating the pin").
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication and one trusted temporary folder. A few Sonnet turns are
# submitted (about three minutes). FM_BRANCH_MOD_LIVE_KEEP=1 copies the lab's
# logs (module events, Claude debug, watcher triage, status) to a fresh
# temporary directory named on stdout, for a post-mortem.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M2Q2CXM0BVV02EKXF82Q5RAT/tests/lib.sh"

fm_live_gate opt-in FM_BRANCH_MOD_LIVE claude tmux

MOD="$ROOT/.claude/mods/fm-branch-mod"
PIN=$(sed -n "s/^export const CLAUDE_CODE_PIN = '\([0-9.]*\)'$/\1/p" "$MOD/hooks/branch.ts")
[ -n "$PIN" ] || fail "the module declares no CLAUDE_CODE_PIN"
CLAUDE_VERSION=$(claude --version 2>/dev/null | awk '{ print $1 }')
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
if [ "$CLAUDE_VERSION" != "$PIN" ]; then
  echo "skip: Claude Code $CLAUDE_VERSION installed, the supervision-branch mod is pinned to $PIN"
  exit 0
fi

REAL_TMUX=$(command -v tmux)
LAB=$(fm_test_tmproot fm-branch-claude-live)
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"
EVENTS="$STATE/branch-mod-events.jsonl"
SHIM="$LAB/shim"
SOCKET="fm-branch-claude-$$"
SESSION="fm-branch-e2e"

cleanup() {
  local i=0 keep
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  # The watcher and Claude's debug logger may still be winding down in the lab.
  while [ "$i" -lt 20 ] && pgrep -f "$LAB/" >/dev/null 2>&1; do
    sleep 0.25
    i=$((i + 1))
  done
  pkill -f "$LAB/" 2>/dev/null || true
  if [ "${FM_BRANCH_MOD_LIVE_KEEP:-}" = 1 ] && keep=$(mktemp -d "${TMPDIR:-/tmp}/fm-branch-claude-live-logs.XXXXXX"); then
    cp "$EVENTS" "$LAB/debug.log" "$STATE/.watch-triage.log" "$STATE/dummy.status" "$STATE/.wake-queue" "$keep/" 2>/dev/null || true
    echo "# lab logs kept at $keep"
  fi
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# --- scratch home ------------------------------------------------------------
# Scripts come from the tracked bin/ through a symlink overlay so the home is a
# genuine primary checkout for the Stop hook's scope check; the mod resolves
# them from its own plugin root either way.
mkdir -p "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects/dummy" "$HOME_DIR/bin" "$SHIM"
for f in "$ROOT"/bin/*; do ln -s "$f" "$HOME_DIR/bin/$(basename "$f")"; done
for d in .agents docs .tasks.toml; do ln -s "$ROOT/$d" "$HOME_DIR/$d"; done
git -C "$HOME_DIR" init -q
printf 'tmux\n' > "$HOME_DIR/config/backend"
: > "$STATE/.branch-mod-mode"
cat > "$HOME_DIR/AGENTS.md" <<'MD'
# Scratch primary for the fm-branch-mod live regression

You are the MAIN conversation of a scratch firstmate home used by a regression test. Do exactly what a prompt asks and nothing more.

- First prompt of a session: run `bin/fm-lock.sh` (it takes this home's session lock), then reply `ready` and idle.
- A watcher wake reaches you only when the plugin routed it to you. Handle it: run `bin/fm-wake-drain.sh`, read what it prints, then reply to the captain in one or two plain sentences with the outcome, and finally run the exact `--ack-through` command the drain printed as `WAKE_ACK_REQUIRED`. Do not run `bin/fm-watch-arm.sh`.
- A `STATUS OUTCOME BACKSTOP` section in the drain names a captain-facing status line the supervision branch had marked routine: tell the captain about it in one sentence.
- A supervision processing request (`[seq N] task: summary`) asks you to tell the captain the outcome in one sentence, then call `fm_branch_processed` with `through=N`.
- Otherwise, if a routine operational update needs a reply, answer exactly `Captain, shipshape.`
- Never spawn agents, never edit files, never run anything outside `bin/`.
MD
printf '@AGENTS.md\n' > "$HOME_DIR/CLAUDE.md"
cat > "$STATE/dummy.meta" <<EOF
window=$SESSION:dummy
worktree=$HOME_DIR/projects/dummy
project=$HOME_DIR/projects/dummy
harness=claude
kind=scout
backend=tmux
EOF
: > "$STATE/dummy.status"

# The stand-in crewmate: a routine `working:` line every <period> seconds, a
# tick so its pane is never idle, and one captain-class `done:` line when the
# test drops the request file.
cat > "$LAB/dummy.sh" <<'DUMMY'
#!/usr/bin/env bash
set -u
STATUS=$1; PERIOD=$2; D=$(dirname "$STATUS")
n=0; last=$(date +%s)
while :; do
  now=$(date +%s)
  if [ -e "$D/dummy.done-request" ]; then
    rm -f "$D/dummy.done-request"; n=$((n + 1))
    echo "done: dummy finished step $n; report at data/dummy/report.md" >> "$STATUS"
    echo "$(date +%T) appended done"
  elif [ $((now - last)) -ge "$PERIOD" ]; then
    n=$((n + 1)); last=$now
    echo "working: step $n of the dummy loop, $(date +%T)" >> "$STATUS"
    echo "$(date +%T) appended working step $n"
  else
    echo "$(date +%T) tick"
  fi
  sleep 2
done
DUMMY

# Every bare `tmux` the home's scripts run (watcher, backend reads, the Stop
# hook) lands on this test's private server.
cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
EOF
chmod +x "$SHIM/tmux" "$LAB/dummy.sh"

# The launch settings the docs page prescribes: the Stop-owned watcher auto-arm,
# prompt suggestion off, and no autoCompactWindow.
cat > "$LAB/settings.json" <<EOF
{
  "promptSuggestionEnabled": false,
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' exec '$HOME_DIR/bin/fm-claude-stop-autoarm.sh'",
            "asyncRewake": true,
            "timeout": 28800
          }
        ]
      }
    ]
  }
}
EOF

# Claude Code refuses to nest inside another Claude session, and the home's
# scripts must not inherit this shell's firstmate environment.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR|FM_[A-Z_]+|HERDR_[A-Z_]+|TMUX|TMUX_PANE)=' | cut -d= -f1 | sort -u)
}

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n main -x 160 -y 44 -c "$HOME_DIR" \
  "env $(unset_inherited) PATH='$SHIM:$PATH' CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model sonnet --plugin-dir '$MOD' --settings '$LAB/settings.json' --strict-mcp-config --dangerously-skip-permissions --debug-file '$LAB/debug.log'; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"

screen() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:main" 2>/dev/null || true
}

enter() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" Enter
}

# The folder-trust dialog opens with its cursor on "No, exit": move the cursor
# onto the trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 0 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) enter ;;
    *) "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" Down ;;
  esac
}

events() {  # <kind> -> the matching event lines
  grep -F "\"kind\":\"$1\"" "$EVENTS" 2>/dev/null || true
}

# Wait until an event of <kind> whose line contains <needle> has been logged,
# answering the folder-trust dialog on the way; iteration-counted so it
# stretches under load.
wait_event() {  # <kind> <needle> <what> [seconds]
  local kind=$1 needle=$2 what=$3 limit=${4:-240} i=0 shot
  while [ "$i" -lt "$((limit * 2))" ]; do
    if events "$kind" | grep -qF -- "$needle"; then return 0; fi
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
    esac
    answer_trust_dialog "$shot"
    sleep 0.5
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  tail -n 20 "$EVENTS" >&2 2>/dev/null || true
  fail "Claude Code $CLAUDE_VERSION never reached $what"
}

count() {  # <kind> [needle]
  if [ "$#" -gt 1 ]; then events "$1" | grep -cF -- "$2" || true; else events "$1" | wc -l | tr -d ' '; fi
}

# --- 1. load and lock ---------------------------------------------------------
wait_event session.start '"enabled":true' 'the module loading enabled'
[ "$(count pin.refused)" = 0 ] || fail "the module refused its own pin"
# The composer is up once the trust dialog is gone and the prompt glyph shows.
i=0
while [ "$i" -lt 240 ]; do
  shot=$(screen)
  answer_trust_dialog "$shot"
  case "$shot" in *'❯'*) [ "$i" -gt 4 ] && break ;; esac
  sleep 0.5
  i=$((i + 1))
done
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" -l "Take this home's session lock with bin/fm-lock.sh, then reply ready."
sleep 0.5
enter
wait_event turn.complete.main '"kind":"turn.complete.main"' "main's lock turn"
[ -s "$STATE/.lock" ] || fail "main did not take the session lock"
pass "Claude Code $CLAUDE_VERSION loads the supervision-branch mod enabled and main holds the session lock"

# --- 2. routine wake: spawn ----------------------------------------------------
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION" -n dummy -c "$HOME_DIR" "bash '$LAB/dummy.sh' '$STATE/dummy.status' 5"
wait_event classifier '"verdict":"routine"' "the classifier's routine verdict on the working line"
wait_event wake.delivered '"via":"spawn"' 'the first wake delivered by spawning the branch'
wait_event report.call '"verdict":"routine"' "the branch's routine outcome"
wait_event turn.complete.branch '"kind":"turn.complete.branch"' "the branch's first turn end"
pass "the first routine wake passes the classifier and spawns the branch agent, which reports it routine"

# --- 3. make the branch agent unresumable, then expect a rotation -------------
AGENT_ID=$(grep -o '"agentId":"[^"]*"' "$EVENTS" | head -1 | cut -d'"' -f4)
[ -n "$AGENT_ID" ] || fail "no agentId in the spawn event"
TRANSCRIPT=$(find "$HOME/.claude/projects" -path "*/subagents/agent-$AGENT_ID.jsonl" 2>/dev/null | head -1)
[ -n "$TRANSCRIPT" ] || fail "no transcript on disk for agent $AGENT_ID"
echo "# deleting $TRANSCRIPT (simulates a bridge primary that never writes it)"
rm -f "$TRANSCRIPT"
wait_event agent.send 'could not be resumed' 'SendMessage answering the missing-transcript resume failure' 300
wait_event agent.rotated '"why":"unresumable"' 'the rotation on the unresumable agent' 60
wait_event agent.spawn '"name":"fm-branch-2"' 'the fresh fm-branch-2 spawn' 60
wait_event wake.delivered '"via":"spawn","detail"' 'the wake delivered to fm-branch-2 by spawn' 60
i=0
while [ "$(count report.call)" -lt 2 ] && [ "$i" -lt 480 ]; do sleep 0.5; i=$((i + 1)); done
[ "$(count report.call)" -ge 2 ] || fail "fm-branch-2 never reported: $(events report.call)"
[ "$(count wake.passed 'delivery failed via send')" = 0 ] || fail "a wake was passed to main as a failed send: $(events wake.passed)"
[ "$(count agent.spawn)" = 2 ] || fail "expected two spawns, got $(count agent.spawn)"
pass "an unresumable branch agent rotates to fm-branch-2, which handles the wake; no wake passed to main as a failed send"
# --- 4. the wake after the rotation reaches fm-branch-2 through SendMessage --
wait_event agent.send '"to":"fm-branch-2"' 'a SendMessage to fm-branch-2' 300
i=0
while ! events agent.send | grep -F '"to":"fm-branch-2"' | grep -qF '\"success\":true' && [ "$i" -lt 600 ]; do sleep 0.5; i=$((i + 1)); done
events agent.send | grep -F '"to":"fm-branch-2"' | grep -qF '\"success\":true' || fail "no successful send to fm-branch-2: $(events agent.send | grep -F fm-branch-2)"
[ "$(count agent.spawn)" = 2 ] || fail "a third spawn happened: $(events agent.spawn)"
pass "the next routine wake reaches fm-branch-2 through SendMessage with no further spawn"
echo "COUNTERS: $(cat "$STATE/.branch-mod-counters")"
