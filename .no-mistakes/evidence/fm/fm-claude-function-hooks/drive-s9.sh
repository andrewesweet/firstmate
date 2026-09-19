#!/usr/bin/env bash
set -u
WT=/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M2XHT6APT02FNX3XQGP96E2G
say() { printf "\n### %s\n" "$*"; }
show() { printf "%s\n" "$1" | sed "s/--settings .*//" ; }
say "S9 inheritance chain: primary touch -> fm-config-push -> secondmate home has empty regular file -> spawn from that home carries prefix"
(
H=$(mktemp -d /tmp/sm-helpers.XXXXXX)
grep -v '^test_[a-z_]*$' "$WT/tests/fm-secondmate-harness.test.sh" > "$H/helpers.sh"
sed -i "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/#$WT/tests/#g" "$H/helpers.sh"
. "$H/helpers.sh"
. "$WT/tests/fixtures.sh"
w=$(new_world hooks-chain); head=$(git -C "$w/main" rev-parse HEAD); add_sm_worktree "$w" sm "$head"
touch "$w/home/config/claude-function-hooks"
out=$(run_config_push "$w" 2>&1); echo "push rc=$? :: $(grep -i hooks <<<"$out")"
ls -la "$w/sm/config/claude-function-hooks"
# now spawn a crewmate FROM the secondmate home (its config dir is the pushed copy)
d="$w/smspawn"; SH="$w/sm"; mkdir -p "$SH/state" "$SH/data" "$SH/projects"; touch "$SH/state/.last-watcher-beat"
printf 'claude\n' > "$SH/config/crew-harness"
FB=$(fm_test_make_spawn_fakebin "$d/fake" gh gh-axi pi); printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$FB/timeout"; chmod +x "$FB/timeout"
fm_git_worktree "$d/project" "$d/wt" wt-chain; fm_test_spawn_brief "$SH" c1
LOG="$d/launch.log"; : > "$LOG"
CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LOG" GROK_HOME="$SH/grok" fm_test_run_spawn "$SH" "$d/wt" "$FB" c1 "$d/project" --mode no-mistakes --yolo off 2>&1 | grep spawned
L=$(cat "$LOG"); show "$L"
grep -q 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_FORCE' <<<"$L" && echo "S9 PASS" || echo "S9 FAIL"
say "S9b primary removes flag -> push removes secondmate copy -> next spawn from secondmate home has no prefix"
rm "$w/home/config/claude-function-hooks"; out=$(run_config_push "$w" 2>&1); echo "push rc=$?"
[ -e "$w/sm/config/claude-function-hooks" ] && echo "copy still present" || echo "secondmate copy removed"
: > "$LOG"; fm_test_spawn_brief "$SH" c2
CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LOG" GROK_HOME="$SH/grok" fm_test_run_spawn "$SH" "$d/wt" "$FB" c2 "$d/project" --mode no-mistakes --yolo off 2>&1 | grep spawned
grep -q FUNCTION_HOOKS "$LOG" && echo "S9b FAIL" || echo "S9b PASS"
rm -rf "$H"
)
