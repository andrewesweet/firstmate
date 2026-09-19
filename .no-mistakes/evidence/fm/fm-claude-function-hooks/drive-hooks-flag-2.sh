#!/usr/bin/env bash
# Part 2: S2 (fixed normalisation), S8 relaunch, S9 secondmate inheritance chain.
set -u
WT=/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M2XHT6APT02FNX3XQGP96E2G
say() { printf '\n### %s\n' "$*"; }
show() { printf '%s\n' "$1" | sed 's/--settings .*//' ; }

say "S2 absent file -> launch byte-for-byte identical to base commit e711c40 (ROOT path normalised)"
BASE_SRC=$(mktemp -d /tmp/fm-base.XXXXXX); git -C "$WT" archive e711c407e3ea30d909f1ef11adb8d555113362d7 | tar -x -C "$BASE_SRC"
(
. "$WT/tests/fixtures.sh"; TMP_ROOT=$(fm_test_tmproot hooks-drive2)
run_one() { # <root> <name>
  local d="$TMP_ROOT/$2" H P W LOG FB
  H="$d/home"; P="$d/project"; W="$d/wt"; LOG="$d/launch.log"
  FB=$(fm_test_make_spawn_fakebin "$d/fake" gh gh-axi pi)
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$FB/timeout"; chmod +x "$FB/timeout"
  fm_test_spawn_home "$H" claude; fm_git_worktree "$P" "$W" "wt-$2"; fm_test_spawn_brief "$H" t2
  : > "$LOG"; ROOT="$1" CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LOG" GROK_HOME="$H/grok" fm_test_run_spawn "$H" "$W" "$FB" t2 "$P" --mode no-mistakes --yolo off >/dev/null 2>&1
  sed -e "s#$d/#CASE/#g" -e "s#$1/#ROOT/#g" "$LOG"
}
NEW=$(run_one "$WT" new); OLD=$(run_one "$BASE_SRC" base)
if [ "$NEW" = "$OLD" ]; then echo "S2 PASS: absent-flag claude launch identical to base commit"; show "$NEW"; else echo "S2 FAIL"; diff <(echo "$OLD") <(echo "$NEW"); fi
)
rm -rf "$BASE_SRC"

say "S8 control-plane relaunch (fm-control.sh relaunch) with flag present -> replacement launch carries prefix"
(
H=$(mktemp -d /tmp/relaunch-helpers.XXXXXX)
grep -v '^test_[a-z_]*$' "$WT/tests/fm-control-relaunch.test.sh" > "$H/helpers.sh"
sed -i "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$WT/tests/lib.sh#" "$H/helpers.sh"
. "$H/helpers.sh"
dir=$(new_case hooks rl9); add_ship_task "$dir" rl9 claude
mkdir -p "$dir/home/config"; touch "$dir/home/config/claude-function-hooks"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl9); printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/rl9.meta"
out=$(run_control "$dir" rl9 relaunch --note "hooks relaunch"); rc=$?
echo "rc=$rc"; echo "$out" | tail -2
L=$(grep 'encode launch-brief' "$dir/fake/literal"); show "$L"
grep -q 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_FORCE' <<<"$L" && echo "S8 PASS" || echo "S8 FAIL"
say "S8b same relaunch with flag removed -> no prefix"
rm "$dir/home/config/claude-function-hooks"; : > "$dir/fake/literal"; printf 'claude' > "$dir/fake/command"
out=$(run_control "$dir" rl9 relaunch --note "hooks relaunch off"); rc=$?; echo "rc=$rc"
L=$(grep 'encode launch-brief' "$dir/fake/literal"); show "$L"
grep -q FUNCTION_HOOKS <<<"$L" && echo "S8b FAIL" || echo "S8b PASS"
rm -rf "$H"
)

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
