#!/usr/bin/env bash
set -u
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M58CXV1J8BG12BY1ZW73N6HQ
LAB=$(mktemp -d "$PWD/l.XXXXXX")
printf '%s\n' "$LAB" > .test-tmp/live-lab-path
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -S - -t primary > "$EVIDENCE/claude-live-pane.txt" 2>/dev/null || true
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  for p in "$LAB/state/.watch.lock/pid"; do
    [ ! -f "$p" ] || kill -TERM "$(cat "$p")" 2>/dev/null || true
  done
  for file in hook-events.log hook.err .claude-autoarm-epoch .supervision-host.log; do
    [ ! -f "$LAB/state/$file" ] || cp "$LAB/state/$file" "$EVIDENCE/claude-live-${file#.}"
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
PATH="$FM_HOME/faultbin:$PATH" "$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$FM_HOME/state/stop-payload.json" > "$FM_HOME/state/hook.out" 2> "$FM_HOME/state/hook.err"
rc=$?
printf 'Stop auto-arm returned %s\n' "$rc" >> "$FM_HOME/state/hook-events.log"
cat "$FM_HOME/state/hook.out"
cat "$FM_HOME/state/hook.err" >&2
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
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$EVIDENCE/claude-live-startup.txt"
cat "$EVIDENCE/claude-live-startup.txt"
for ((i=0; i<180; i++)); do
  [ ! -e "$LAB/state/hook-events.log" ] || break
  sleep 1
done
