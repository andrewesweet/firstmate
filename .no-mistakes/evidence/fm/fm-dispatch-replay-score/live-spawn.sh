#!/usr/bin/env bash
# Live spawn on a private real tmux socket; fake claude harness so nothing real launches.
set -u
ROOT=/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M344JE766WDVTF6BVJ3B0198
. "$ROOT/tests/fixtures.sh"
REAL_TMUX=$(command -v tmux); SOCK="fm-live-score-$$"
trap '"$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
TMP=$(mktemp -d); HOME_DIR=$TMP/home; PROJ=$TMP/project; WT=$TMP/wt
FAKEBIN=$(fm_fakebin "$TMP/fake")
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" treehouse
printf '#!/usr/bin/env bash\nsleep 4\n' > "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$PROJ" "$WT" wt-live
fm_test_spawn_brief "$HOME_DIR" live-ship-1
fm_test_spawn_brief "$HOME_DIR" live-scout-1
fm_test_spawn_brief "$HOME_DIR" live-ship-2
printf '%s\n' '{"rules":[{"when":"Fast work.","use":{"harness":"codex","model":"gpt-5","effort":"medium"}},{"when":"Scouting.","use":{"harness":"claude"}}],"default":{"harness":"claude","model":"opus"}}' > "$HOME_DIR/config/crew-dispatch.json"
# Real bin/fm-dispatch-resolve.sh against a fake typesafe API (fake curl + quota-axi from the resolver suite's shape).
RES=$TMP/res; mkdir -p "$RES"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
out=''; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cat > /dev/null; cp "${FAKE_CURL_RESPONSE:?}" "$out"; printf 200
SH
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":79,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.4}}]}},{"provider":"codex","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":31,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.16}}]}}]}'
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/quota-axi"
resolve() {  # <id> <choice> <confidence>
  printf '{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"%s","confidence":%s,"probabilities":{"rule_1":0.3,"rule_2":0.3,"default":0.4}}},"usage":{"input_tokens":100,"output_tokens":5}}\n' "$2" "$3" > "$RES/resp.json"
  FAKE_CURL_RESPONSE="$RES/resp.json" TYPESAFE_API_KEY=fake-key PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-dispatch-resolve.sh" "$HOME_DIR/data/$1/brief.md" --project live
}
echo "== resolver (real script, fake API) for the three tasks"
resolve live-ship-1 rule_1 0.83; resolve live-scout-1 rule_2 0.71; resolve live-ship-2 rule_1 0.52
echo "== data/dispatch-resolve.jsonl"; jq -c '{ts,task,status,confidence,rule,profile,selected_option}' "$HOME_DIR/data/dispatch-resolve.jsonl"
"$REAL_TMUX" -L "$SOCK" new-session -d -s firstmate -c "$WT" -x 200 -y 50
# Panes run a non-login bash with the fake harness first on PATH: no real claude, no real treehouse.
printf 'treehouse() { cd -- %q; }\nPS1="$ "\n' "$WT" > "$TMP/rc"
"$REAL_TMUX" -L "$SOCK" set -g default-command "env PATH=$FAKEBIN:$PATH bash --noprofile --rcfile $TMP/rc"
"$REAL_TMUX" -L "$SOCK" set -g remain-on-exit off
TMUX_VAL=$("$REAL_TMUX" -L "$SOCK" display-message -p '#{socket_path},#{pid},0')
mkdir -p "$HOME_DIR/user-home"
spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 TMUX="$TMUX_VAL" TMUX_PANE=%0 PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$@"
}
echo "== ship spawn"; spawn live-ship-1 "$PROJ" --harness claude --model sonnet --effort high --mode no-mistakes --yolo off; echo "exit=$?"
echo "== scout spawn"; spawn live-scout-1 "$PROJ" --scout --harness claude; echo "exit=$?"
echo "== tmux windows"; "$REAL_TMUX" -L "$SOCK" list-windows -t firstmate -F '#{window_name} #{pane_current_command}'
echo "== stop agent in ship pane, then relaunch"
"$REAL_TMUX" -L "$SOCK" send-keys -t firstmate:fm-live-ship-1 C-c; sleep 6
"$REAL_TMUX" -L "$SOCK" list-windows -t firstmate -F '#{window_name} #{pane_current_command}'
spawn live-ship-1 --relaunch --harness claude; echo "exit=$?"
"$REAL_TMUX" -L "$SOCK" list-windows -t firstmate -F '#{window_name} #{pane_current_command}'
echo "== data/dispatch-spawns.jsonl"; cat "$HOME_DIR/data/dispatch-spawns.jsonl"
echo "lines=$(wc -l < "$HOME_DIR/data/dispatch-spawns.jsonl")"

echo "== unwritable spawn log: spawn still succeeds, one stderr line"
chmod 444 "$HOME_DIR/data/dispatch-spawns.jsonl"
spawn live-ship-2 "$PROJ" --harness claude --mode no-mistakes --yolo off 2> "$TMP/err"; echo "exit=$?"; grep 'dispatch-spawn' "$TMP/err"
chmod 644 "$HOME_DIR/data/dispatch-spawns.jsonl"
echo "lines=$(wc -l < "$HOME_DIR/data/dispatch-spawns.jsonl")"

BEFORE=$(sha256sum "$HOME_DIR/data/dispatch-resolve.jsonl" "$HOME_DIR/data/dispatch-spawns.jsonl")
echo "== score the live spawn log against the real resolver log (resolver picked codex for ship-1, claude for scout-1; label for scout-1 is the rule id, which must not count)"
printf '# adjudicated\nlive-ship-1\tFast work.\nlive-scout-1\trule_2\nlive-ship-2\tFast work.\n' > "$HOME_DIR/data/labels.tsv"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-dispatch-resolve-score.sh" --labels "$HOME_DIR/data/labels.tsv"; echo "exit=$?"
echo "== score without labels, default FM_HOME paths"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-dispatch-resolve-score.sh"; echo "exit=$?"
echo "== scorer left both logs unchanged"
[ "$BEFORE" = "$(sha256sum "$HOME_DIR/data/dispatch-resolve.jsonl" "$HOME_DIR/data/dispatch-spawns.jsonl")" ] && echo "logs unchanged: yes" || echo "logs unchanged: NO"
echo "HOME_DIR=$HOME_DIR"
