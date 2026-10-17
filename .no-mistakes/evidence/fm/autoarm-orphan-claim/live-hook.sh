#!/usr/bin/env bash
set -u
export FM_CHECK_INTERVAL=1 FM_POLL=1 FM_HEARTBEAT=999999
kind=$1
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_HOME/state/$kind-payloads.jsonl"
printf 'kind=%s pid=%s ppid=%s CLAUDE_PID=%s session=%s\n' "$kind" "$$" "$PPID" "${CLAUDE_PID:-}" "${CLAUDE_CODE_SESSION_ID:-}" >> "$FM_HOME/state/hooks.log"
if [ "$kind" = start ]; then
  "$CLAUDE_PROJECT_DIR/bin/fm-lock.sh" >> "$FM_HOME/state/start.log" 2>&1
else
  if [ -f "$FM_HOME/state/probe-next-stop" ]; then
    python3 "$CLAUDE_PROJECT_DIR/.test-validation/live-guard-matrix.py"
    printf 'probe_rc=%s\n' "$?" >> "$FM_HOME/state/hooks.log"
  fi
  printf '%s\n' "$payload" | "$CLAUDE_PROJECT_DIR/bin/fm-claude-stop-autoarm.sh" 2> >(tee -a "$FM_HOME/state/stop-feedback.log" >&2)
  rc=$?
  printf 'stop_rc=%s\n' "$rc" >> "$FM_HOME/state/hooks.log"
  exit "$rc"
fi
