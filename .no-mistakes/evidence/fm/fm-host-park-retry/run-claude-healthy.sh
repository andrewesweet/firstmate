#!/usr/bin/env bash
set -u
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M58CXV1J8BG12BY1ZW73N6HQ
LAB=$(mktemp -d "$PWD/l.XXXXXX")
printf '%s\n' "$LAB" > .test-tmp/healthy-lab-path
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -S - -t primary > "$EVIDENCE/claude-healthy-pane.txt" 2>/dev/null || true
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  for p in "$LAB/state/.watch.lock/pid"; do
    [ ! -f "$p" ] || kill -TERM "$(cat "$p")" 2>/dev/null || true
  done
  for file in health-evidence.log independent-arm.out shared-guard.out hook-events.log hook.err .claude-autoarm-epoch .supervision-host.log; do
    [ ! -f "$LAB/state/$file" ] || cp "$LAB/state/$file" "$EVIDENCE/claude-healthy-${file#.}"
  done
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/faultbin"
cp -R bin "$LAB/bin"
ln -s "$ROOT/AGENTS.md" "$LAB/AGENTS.md"
git -C "$LAB" init -q
: > "$LAB/config/supervision-host"
printf 'project=probe\nwindow=primary\nharness=claude\nbackend=tmux\n' > "$LAB/state/probe.meta"
REAL_MKTEMP=$(command -v mktemp)
cat > "$LAB/faultbin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in *'/.supervision-host-arm.'*)
  printf 'real host attempted watcher cycle; injected mktemp failure\n' >> "\$FM_HOME/state/hook-events.log"
  exit 1 ;;
esac
exec "$REAL_MKTEMP" "\$@"
SH
chmod +x "$LAB/faultbin/mktemp"
cat > "$LAB/observe-hook.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_HOME/state/stop-payload.json"
[ -f "$FM_HOME/state/probe.meta" ] || exit 0
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
 touch "$FM_HOME/state/.last-check" "$FM_HOME/state/.last-heartbeat"
"$FM_HOME/bin/fm-watch-arm.sh" > "$FM_HOME/state/independent-arm.out" 2>&1 &
arm=$!
. "$FM_HOME/bin/fm-wake-lib.sh"
healthy=1
for ((i=0;i<150;i++)); do
  fm_watcher_healthy "$FM_HOME/state" "$FM_HOME/bin/fm-watch.sh" 300 "$FM_HOME" && { healthy=0; break; }
  sleep 0.1
done
printf 'before host failure: real watcher health=%s\n' "$healthy" > "$FM_HOME/state/health-evidence.log"
"$FM_HOME/bin/fm-turnend-guard.sh" --claude < "$FM_HOME/state/stop-payload.json" > "$FM_HOME/state/shared-guard.out" 2>&1
printf 'shared guard status=%s\n' "$?" >> "$FM_HOME/state/health-evidence.log"
PATH="$FM_HOME/faultbin:$PATH" "$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$FM_HOME/state/stop-payload.json" > "$FM_HOME/state/hook.out" 2> "$FM_HOME/state/hook.err"
rc=$?
printf 'Stop auto-arm returned %s\n' "$rc" >> "$FM_HOME/state/hook-events.log"
fm_watcher_healthy "$FM_HOME/state" "$FM_HOME/bin/fm-watch.sh" 300 "$FM_HOME"
printf 'after host failure: real watcher health=%s\n' "$?" >> "$FM_HOME/state/health-evidence.log"
cat "$FM_HOME/state/hook.out"
cat "$FM_HOME/state/hook.err" >&2
kill -TERM "$arm" 2>/dev/null || true
wait "$arm" 2>/dev/null || true
python3 -c 'import os; os.unlink(os.environ["FM_HOME"]+"/state/probe.meta")'
exit "$rc"
SH
chmod +x "$LAB/observe-hook.sh"
python3 - "$LAB" <<'PYSET'
import json,sys
from pathlib import Path
lab=Path(sys.argv[1])
settings={'hooks':{
'SessionStart':[{'hooks':[{'type':'command','command':str(lab/'bin/fm-lock.sh')}]}],
'Stop':[{'hooks':[{'type':'command','command':str(lab/'observe-hook.sh'),'asyncRewake':True,'timeout':120}]}]
},'permissions':{'deny':['Bash','Agent','Task','Write','Edit','NotebookEdit']},'feedbackDrafts':'off'}
(lab/'settings.json').write_text(json.dumps(settings))
PYSET
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE -u CLAUDE_PID -u PI_CODING_AGENT TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 160 -y 45 -c "$PWD" -e FM_HOME="$LAB" -e CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model haiku --settings "$LAB/settings.json" --strict-mcp-config --mcp-config '{"mcpServers":{}}'
sleep 5
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$EVIDENCE/claude-healthy-startup.txt"
cat "$EVIDENCE/claude-healthy-startup.txt"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary -l 'This is an isolated product check. Run no tools. Reply READY and stop. If Stop feedback reports firstmate watcher auto-arm FAILED, reply exactly HEALTHY_FAILURE_RECEIVED and stop. Make no repairs.'
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary Enter
for ((i=0; i<90; i++)); do
  if TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -S - -t primary | grep -q '^● HEALTHY_FAILURE_RECEIVED'; then
    sleep 3
    break
  fi
  sleep 1
done
