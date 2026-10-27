#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
SOCKET="$PWD/.t/m"
REAL_TMUX=$(command -v tmux)
tmux() { "$REAL_TMUX" -f /dev/null -S "$SOCKET" "$@"; }
cleanup() { tmux kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
. bin/fm-backend.sh
fm_backend_source tmux
tmux new-session -d -s fm-lab-check -n primary -x 120 -y 40 -c "$PWD/.t" 'bash --noprofile --norc'
tmux set-option -g default-command 'bash --noprofile --norc'
tmux new-session -d -s fm-lab-check-other -n fm-task -x 120 -y 40 -c "$PWD/.t" 'bash --noprofile --norc'
T=fm-lab-check:fm-task
printf 'Create isolated task and refuse duplicate\n'
fm_backend_tmux_create_task fm-lab-check fm-task "$PWD/.t"
if fm_backend_tmux_create_task fm-lab-check fm-task "$PWD/.t"; then exit 1; fi
printf 'Sized grid: '; tmux display-message -p -t "$T" '#{pane_width}x#{pane_height}'
wait_text() {
  for i in $(seq 1 50); do
    output=$(fm_backend_tmux_capture "$T" 100)
    [[ "$output" == *"$1"* ]] && return 0
    sleep .1
  done
  return 1
}
fm_backend_tmux_send_text_line "$T" "printf 'ready-%s\\n' shell"
wait_text ready-shell
fm_backend_tmux_send_text_line "$T" "printf 'single-%s\\n' submitted"
wait_text single-submitted
fm_backend_tmux_send_literal "$T" "printf 'literal-%s\\n' submitted"
fm_backend_tmux_send_key "$T" Enter
wait_text literal-submitted
printf '\nCaptured actual shell output (result tokens absent from typed commands):\n'
fm_backend_tmux_capture "$T" 100
state=$(fm_backend_tmux_agent_state "$T")
printf 'Shell-only task agent state: %s\n' "$state"
[ "$state" = dead ]
fm_backend_tmux_kill "$T"
state=$(fm_backend_tmux_agent_state "$T")
printf 'Task agent state after close: %s\n' "$state"
[ "$state" = missing ]
tmux list-windows -t =fm-lab-check-other -F '#{window_name}' | grep -qx fm-task
printf 'Same-named task in other session survives exact close.\n'
fm_backend_tmux_kill "$T"
printf 'Repeated close succeeds.\n'
