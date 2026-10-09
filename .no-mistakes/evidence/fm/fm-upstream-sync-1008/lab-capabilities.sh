#!/usr/bin/env bash
set -u
EV=/home/cti/.no-mistakes/evidence/01M4FC0EXAEYKAXXQKZKTGBDFH
export FM_HERDR_LAB_STATE_DIR="$EV/herdr-lab-state"
SESSION=$(bin/fm-herdr-lab.sh name upstream-sync)
if bin/fm-herdr-lab.sh prepare "$SESSION"; then
  trap 'bin/fm-herdr-lab.sh teardown "$SESSION"' EXIT
  if bin/fm-herdr-lab.sh provision "$SESSION"; then
    bin/fm-herdr-lab.sh run "$SESSION" status
  fi
  bin/fm-herdr-lab.sh teardown "$SESSION"
  trap - EXIT
fi
LAB=$(mktemp -d "$PWD/.validation-tmp/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB"
SOCKET_DIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
cleanup() {
  TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
  bin/fm-lab-home.sh teardown "$LAB"
  rm -rf "$LAB"
}
trap cleanup EXIT
touch "$LAB/config/supervision-host"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" claude
sleep 8
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t primary
printf '\nCLI versions and login state:\n'
claude --version
codex --version
pi --version
treehouse --version
codex login status 2>&1
