#!/usr/bin/env bash
# Live lab: real Claude Code 2.1.278 in tmux with the supervision-branch mod
# loaded (mode file present). Argument 1 = "lock" (state/.lock pre-held) or
# "nolock". No prompt is ever submitted. Observes the mod's event log.
set -u
ROOT=$1; MODE=$2; EV=$3
MOD="$ROOT/.claude/mods/fm-branch-mod"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-live-$MODE-$$"; SESSION=fm-live
LAB=$(mktemp -d /tmp/fm-live-XXXXXX); HOME_DIR="$LAB/home"; STATE="$HOME_DIR/state"; SHIM="$LAB/shim"
EVENTS="$STATE/branch-mod-events.jsonl"
mkdir -p "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/bin" "$SHIM"
for f in "$ROOT"/bin/*; do ln -s "$f" "$HOME_DIR/bin/$(basename "$f")"; done
for d in .agents docs .tasks.toml; do ln -s "$ROOT/$d" "$HOME_DIR/$d"; done
git -C "$HOME_DIR" init -q
printf 'tmux\n' > "$HOME_DIR/config/backend"
: > "$STATE/.branch-mod-mode"
printf '# scratch\n' > "$HOME_DIR/CLAUDE.md"
case "$MODE" in
  lock) printf '%s\n' "$$" > "$STATE/.lock" ;;
  legacy) printf '%s\n' "$$" > "$STATE/.lock"
    printf '{"lockPid":"%s","wakeCounter":0,"spawnCount":0,"sendCount":0,"generation":"old","branchGeneration":1,"branchRef":"","branchAgentId":"","monitorTaskId":"m-old"}\n' "$$" > "$STATE/.branch-mod-counters" ;;
esac
cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
EOF
chmod +x "$SHIM/tmux"
printf '{ "promptSuggestionEnabled": false }\n' > "$LAB/settings.json"
unset_inherited() { env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR|FM_[A-Z_]+|HERDR_[A-Z_]+|TMUX|TMUX_PANE)=' | cut -d= -f1 | sort -u | sed 's/^/-u /' | tr '\n' ' '; }
env $(unset_inherited) "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n main -x 160 -y 44 -c "$HOME_DIR" \
  "env $(unset_inherited) PATH='$SHIM:$PATH' CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model sonnet --plugin-dir '$MOD' --settings '$LAB/settings.json' --strict-mcp-config --dangerously-skip-permissions --debug-file '$LAB/debug.log'; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
screen() { "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:main" 2>/dev/null || true; }
i=0
while [ $i -lt 240 ]; do
  shot=$(screen)
  case "$shot" in *'Yes, I trust this folder'*)
    sel=$(printf '%s\n' "$shot" | grep -F '❯' | head -1)
    case "$sel" in *'Yes, I trust this folder'*) "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" Enter ;; *) "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:main" Down ;; esac ;;
  esac
  if grep -qE '"kind":"(monitor\.armed|monitor\.skipped|monitor\.error|pin\.refused|session\.start)"' "$EVENTS" 2>/dev/null; then break; fi
  sleep 0.5; i=$((i+1))
done
sleep 6
echo "=== screen ($MODE) ==="; screen | grep -v '^\s*$' | head -30
echo "=== events ($MODE) ==="; cat "$EVENTS" 2>/dev/null
echo "=== watcher loop processes ($MODE) ==="; pgrep -af "fm-watch-arm|fm-branch-mod watcher" | grep -v pgrep || echo "(none)"
echo "=== state/.lock ($MODE) ==="; cat "$STATE/.lock" 2>/dev/null || echo "(absent)"
echo "=== counters ($MODE) ==="; cat "$STATE/.branch-mod-counters" 2>/dev/null || echo "(absent)"
cp "$EVENTS" "$EV/live-$MODE-branch-mod-events.jsonl" 2>/dev/null
"$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
sleep 1; pkill -f "$LAB/" 2>/dev/null || true
rm -rf "$LAB"
