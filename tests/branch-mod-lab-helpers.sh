#!/usr/bin/env bash
# Scratch-home fixtures shared by the branch mod's live guard and its portable
# watcher-isolation regression in fm-test-fixtures.test.sh.
# Callers supply ROOT, REAL_TMUX and SESSION; make_lab sets the current lab's
# SOCKET, LAB, HOME_DIR, STATE, EVENTS, SHIM and LAB_TMUX_DIR. Call teardown_lab before
# removing a lab, and retain the test's combined EXIT cleanup.
# shellcheck disable=SC2016 # scratch instructions are consumed by Claude

teardown_lab() { # <socket> <lab>
  local socket=$1 lab=$2 home tmux_dir
  [ -n "$lab" ] || return 0
  home="$lab/home"
  [ -d "$home/state" ] || return 0
  if [ -f "$home/state/.fm-lab-tmux-dir" ]; then
    tmux_dir=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$home") || return 1
    TMUX_TMPDIR="$tmux_dir" "$REAL_TMUX" -L "$socket" kill-server 2>/dev/null || true
  fi
  # Detached handling successors and mod-owned watchers have the code root,
  # not the lab, in argv. Stop only the watcher this home's lock identifies,
  # after killing its primary so no Stop firing can re-arm it during cleanup.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-watch-arm.sh" --stop || return 1
  "$ROOT/bin/fm-lab-home.sh" teardown "$home"
}

# Each scenario runs in its own throwaway home, so the child-session launch
# starts a genuinely fresh Claude session instead of adopting the first lab's
# lock, counters, and agent. Scripts come from the tracked bin/ through a
# symlink overlay so the home is a genuine primary checkout for the Stop
# hook's scope check; the mod resolves them from its own plugin root either
# way.
make_lab() { # <socket>: build a fresh scratch home; sets the lab globals
  SOCKET=$1
  LAB=$(fm_test_tmproot fm-branch-claude-live) || return 1
  HOME_DIR="$LAB/home"
  STATE="$HOME_DIR/state"
  # shellcheck disable=SC2034 # Read by the live guard's events() helper.
  EVENTS="$STATE/branch-mod-events.jsonl"
  SHIM="$LAB/shim"
  "$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || return 1
  LAB_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$HOME_DIR") || return 1
  export TMUX_TMPDIR="$LAB_TMUX_DIR"
  mkdir -p "$HOME_DIR/projects/dummy" "$HOME_DIR/bin" "$SHIM"
for f in "$ROOT"/bin/*; do ln -s "$f" "$HOME_DIR/bin/$(basename "$f")"; done
for d in .agents docs .tasks.toml; do ln -s "$ROOT/$d" "$HOME_DIR/$d"; done
git -C "$HOME_DIR" init -q
printf 'tmux\n' > "$HOME_DIR/config/backend"
: > "$HOME_DIR/config/supervision-host-off"
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
  if [ -e "$D/dummy.pause" ]; then
    last=$now
    echo "$(date +%T) paused"
  elif [ -e "$D/dummy.done-request" ]; then
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
TMUX_TMPDIR='$LAB_TMUX_DIR' exec '$REAL_TMUX' -L '$SOCKET' "\$@"
EOF
chmod +x "$SHIM/tmux" "$LAB/dummy.sh"

# The launch settings the docs page prescribes: the Stop-owned watcher auto-arm,
# prompt suggestion off, and no autoCompactWindow. The hook must run from the
# same tracked bin as the mod: watcher ownership matches the script path
# exactly, so the home's per-file symlink overlay is not an interchangeable
# entry point for these two arm owners.
cat > "$LAB/settings.json" <<EOF
{
  "promptSuggestionEnabled": false,
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' exec '$ROOT/bin/fm-claude-stop-autoarm.sh'",
            "asyncRewake": true,
            "timeout": 28800
          }
        ]
      }
    ]
  }
}
EOF

}
