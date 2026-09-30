#!/usr/bin/env bash
# Launch the real claude binary in a private tmux server whose own environment
# has NO DISABLE_AUTOUPDATER (ambient stripped), once with the launch shape
# from this change (embedded DISABLE_AUTOUPDATER=1) and once without it
# (control), then read the running claude process's /proc environ.
set -u
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-au.XXXXXX")
SOCK="fm-lab-au-$$"
probe() { # <label> <embed>
  local label=$1 embed=$2 pane child found=unset i=0
  env -i HOME="$HOME" PATH="$PATH" TERM=xterm-256color tmux -L "$SOCK" kill-session -t s 2>/dev/null
  env -i HOME="$HOME" PATH="$PATH" TERM=xterm-256color tmux -L "$SOCK" new-session -d -s s -x 160 -y 44 -c "$LAB" \
    "env $embed CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --debug-file '$LAB/debug.log'; sleep 30"
  pane=$(tmux -L "$SOCK" list-panes -t s -F '#{pane_pid}')
  echo "[$label] tmux server global env DISABLE_AUTOUPDATER: $(tmux -L "$SOCK" show-environment -g DISABLE_AUTOUPDATER 2>&1)"
  while [ $i -lt 40 ]; do
    for child in $(pgrep -P "$pane"); do
      found=$(tr '\0' '\n' < /proc/$child/environ | grep '^DISABLE_AUTOUPDATER=' || echo "DISABLE_AUTOUPDATER absent")
      echo "[$label] running pid $child exe=$(readlink /proc/$child/exe) -> $found"
      break 2
    done
    sleep 0.25; i=$((i+1))
  done
  sleep 3
  echo "[$label] pane screen (first lines):"; tmux -L "$SOCK" capture-pane -p -t s | sed -n '1,8p'
}
probe "change launch shape (embedded)" "DISABLE_AUTOUPDATER=1"
probe "control (no embed)" ""
tmux -L "$SOCK" kill-server 2>/dev/null
sleep 1; pkill -f "$LAB/" 2>/dev/null; rm -rf "$LAB"
