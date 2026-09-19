#!/usr/bin/env bash
# split-launch.sh <label> <absolute claude binary> <PATH claude version> [ENV=VAL ...]
# Launches one scratch-home Claude Code primary with the mod, the host binary by
# absolute path, and PATH `claude` a symlink to another release; prints the mod's
# session.start / pin.refused event line, the probe check, and the ui log line.
set -u
LABEL=$1; BIN=$2; PATHVER=$3; shift 3
ROOT=/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M2WP4HBYWBFZN4B05T2AB0MQ
MOD="$ROOT/.claude/mods/fm-branch-mod"
REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d /tmp/fm-split-$LABEL.XXXXXX)
HOME_DIR="$LAB/home"; STATE="$HOME_DIR/state"; SHIM="$LAB/shim"
EVENTS="$STATE/branch-mod-events.jsonl"
SOCKET="fm-split-$LABEL-$$"
mkdir -p "$STATE" "$HOME_DIR/config" "$SHIM"
git -C "$HOME_DIR" init -q
printf 'tmux\n' > "$HOME_DIR/config/backend"
: > "$STATE/.branch-mod-mode"
ln -s "$HOME/.local/share/claude/versions/$PATHVER" "$SHIM/claude"
cat > "$SHIM/tmux" <<T
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
T
chmod +x "$SHIM/tmux"
printf '{"promptSuggestionEnabled": false}\n' > "$LAB/settings.json"
unset_inherited() {
  env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR|FM_[A-Z_]+|HERDR_[A-Z_]+|TMUX|TMUX_PANE)=' | cut -d= -f1 | sort -u | sed 's/^/-u /' | tr '\n' ' '
}
EXTRA="$*"
CMD="env $(unset_inherited) PATH='$SHIM:$PATH' CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 $EXTRA $BIN --model sonnet --plugin-dir '$MOD' --settings '$LAB/settings.json' --strict-mcp-config --dangerously-skip-permissions --debug-file '$LAB/debug.log'; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
echo "## $LABEL"
echo "host binary: $BIN ($("$BIN" --version))"
echo "PATH claude: $SHIM/claude -> $(readlink "$SHIM/claude") ($(PATH="$SHIM:$PATH" claude --version))"
echo "extra env: ${EXTRA:-none}"
echo "launch: $CMD"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s s -n main -x 160 -y 44 -c "$HOME_DIR" "$CMD"
i=0
while [ "$i" -lt 240 ]; do
  if grep -Eq '"kind":"(session\.start|pin\.refused)"' "$EVENTS" 2>/dev/null; then break; fi
  shot=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t s:main 2>/dev/null || true)
  case "$shot" in *'Yes, I trust this folder'*)
    sel=$(printf '%s\n' "$shot" | grep -F '❯' | head -1)
    case "$sel" in *'Yes, I trust this folder'*) "$REAL_TMUX" -L "$SOCKET" send-keys -t s:main Enter ;; *) "$REAL_TMUX" -L "$SOCKET" send-keys -t s:main Down ;; esac ;;
  esac
  case "$shot" in *'CLAUDE_EXIT='*) echo "$shot"; break ;; esac
  sleep 0.5; i=$((i + 1))
done
sleep 2
echo "event log:"
grep -E '"kind":"(session\.start|pin\.refused)"' "$EVENTS" 2>/dev/null || echo "(no session.start / pin.refused event)"
echo "ui log line (from Claude debug log):"
grep -F 'fm-branch-mod:' "$LAB/debug.log" 2>/dev/null | grep -E 'loaded|refusing' | head -2 || true
"$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
sleep 1; pkill -f "$LAB/" 2>/dev/null || true
rm -rf "$LAB"
echo
