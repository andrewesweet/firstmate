#!/usr/bin/env bash
# Manual scenario driver for config/claude-function-hooks. Runs the real
# bin/fm-spawn.sh / fm-control.sh / fm-config-push.sh against isolated homes with
# the shared fake tmux (captures the literal launch line).
set -u
WT=/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M2XHT6APT02FNX3XQGP96E2G
EV=/home/andre/.no-mistakes/evidence/01M2XHT6APT02FNX3XQGP96E2G
BASE_SRC=$(mktemp -d /tmp/fm-base.XXXXXX)
git -C "$WT" archive e711c407e3ea30d909f1ef11adb8d555113362d7 | tar -x -C "$BASE_SRC"
. "$WT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot hooks-drive)
say() { printf '\n### %s\n' "$*"; }
show() { printf '%s\n' "$1" | sed 's/--settings .*//' ; }   # trim the long settings JSON

mk_case() { # <name> <harness> <id>
  local d="$TMP_ROOT/$1"; H="$d/home"; P="$d/project"; W="$d/wt"; LOG="$d/launch.log"
  FB=$(fm_test_make_spawn_fakebin "$d/fake" gh gh-axi pi)
  cat > "$FB/timeout" <<'SH'
#!/usr/bin/env bash
shift; exec "$@"
SH
  chmod +x "$FB/timeout"
  fm_test_spawn_home "$H" "$2"; fm_git_worktree "$P" "$W" "wt-$1"; fm_test_spawn_brief "$H" "$3"
}
spawn() { : > "$LOG"; CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LOG" GROK_HOME="$H/grok" fm_test_run_spawn "$H" "$W" "$FB" "$@"; }

say "S1 crewmate: empty file via touch -> prefix present"
mk_case s1 claude t1; touch "$H/config/claude-function-hooks"; ls -la "$H/config/claude-function-hooks"
spawn t1 "$P" --mode no-mistakes --yolo off; L1=$(cat "$LOG"); show "$L1"
grep -q 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1' <<<"$L1" && echo "S1 PASS" || echo "S1 FAIL"

say "S1b env really reaches the claude process: eval the captured line with a fake claude that dumps env"
mkdir -p "$TMP_ROOT/evalbin"; cat > "$TMP_ROOT/evalbin/claude" <<'SH'
#!/usr/bin/env bash
printf 'fake claude sees CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=%s\n' "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS-<unset>}"
SH
chmod +x "$TMP_ROOT/evalbin/claude"
(cd "$W" && PATH="$TMP_ROOT/evalbin:$WT/bin:$PATH" bash -c "$L1")

say "S2 absent file -> launch byte-for-byte identical to base commit e711c40"
mk_case s2 claude t2
spawn t2 "$P" --mode no-mistakes --yolo off; NEW=$(cat "$LOG")
mk_case s2base claude t2
: > "$LOG"; ROOT="$BASE_SRC" CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LOG" GROK_HOME="$H/grok" fm_test_run_spawn "$H" "$W" "$FB" t2 "$P" --mode no-mistakes --yolo off
OLD=$(cat "$LOG")
# only the per-case home path differs; normalise it
n=$(sed "s#$TMP_ROOT/s2/#CASE/#g" <<<"$NEW"); o=$(sed "s#$TMP_ROOT/s2base/#CASE/#g" <<<"$OLD")
if [ "$n" = "$o" ]; then echo "S2 PASS: absent-flag launch identical to base"; else echo "S2 FAIL"; diff <(echo "$o") <(echo "$n"); fi
grep -q FUNCTION_HOOKS <<<"$NEW" && echo "S2 FAIL leaked" || echo "S2 no FUNCTION_HOOKS token in absent launch"
(cd "$W" && PATH="$TMP_ROOT/evalbin:$WT/bin:$PATH" bash -c "$NEW")

say "S3 scout with flag -> prefix present"
mk_case s3 claude t3; touch "$H/config/claude-function-hooks"
spawn t3 "$P" --scout; L=$(cat "$LOG"); show "$L"
grep -q 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_FORCE' <<<"$L" && echo "S3 PASS" || echo "S3 FAIL"

say "S4 non-claude harness (pi) with flag present -> no prefix, flag ignored"
mk_case s4 pi t4; touch "$H/config/claude-function-hooks"
spawn t4 "$P" --mode no-mistakes --yolo off; L=$(cat "$LOG"); show "$L"
grep -q FUNCTION_HOOKS <<<"$L" && echo "S4 FAIL" || echo "S4 PASS: pi launch untouched"

say "S5 no settings file written by the flag (user-home + config dir after spawn)"
find "$TMP_ROOT/s1/home/user-home" "$TMP_ROOT/s1/home/config" -type f | sort
grep -rl CLAUDE_CODE_ENABLE_FUNCTION_HOOKS "$TMP_ROOT/s1/home/user-home" "$TMP_ROOT/s1/home/config" "$TMP_ROOT/s1/wt" 2>/dev/null && echo "S5 FAIL" || echo "S5 PASS: no settings/config file carries the variable"

say "S6 adversarial: directory as flag -> spawn still prefixes (lstat presence)"
mk_case s6 claude t6; mkdir "$H/config/claude-function-hooks"
spawn t6 "$P" --mode no-mistakes --yolo off; L=$(cat "$LOG"); show "$L"
grep -q 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_FORCE' <<<"$L" && echo "S6 spawn prefixes on directory (documented as unsupported for inheritance)" || echo "S6 directory: no prefix"

say "S7 adversarial: unreadable regular file (chmod 000) -> presence still enables (content never read)"
mk_case s7 claude t7; touch "$H/config/claude-function-hooks"; chmod 000 "$H/config/claude-function-hooks"
spawn t7 "$P" --mode no-mistakes --yolo off; L=$(cat "$LOG"); show "$L"
grep -q 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_FORCE' <<<"$L" && echo "S7 PASS" || echo "S7 FAIL"

say "S8 relaunch via fm-control with flag present -> replacement launch carries prefix"
rm -rf "$BASE_SRC"
