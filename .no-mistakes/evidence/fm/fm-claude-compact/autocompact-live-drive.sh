#!/usr/bin/env bash
# Live drive: spawn crewmate / scout / secondmate (claude) and a codex crewmate
# through bin/fm-spawn.sh with the fake tmux, extract each --settings JSON from
# the captured launch command, parse with jq and report autoCompactWindow.
set -u
ROOTDIR=$1
. "$ROOTDIR/tests/fixtures.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-autocompact-live)
# reuse the dispatch-profile suite's helpers (fake pi/cursor probes, run_spawn ...)
eval "$(sed -n '/^make_spawn_pi_probe()/,/^read_case_record() {/p' "$ROOT/tests/fm-spawn-dispatch-profile.test.sh" | sed '$d')"
read_case_record() { IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<<"$1"; }

settings_json() {  # print the --settings '<json>' argument from a launch line
  sed -n "s/.*--settings '\({[^']*}\)'.*/\1/p" "$1"
}
report() {  # <label> <launchlog>
  local label=$1 log=$2 json
  if ! grep -q -- "--settings '" "$log"; then
    printf '%-22s no --settings flag in launch (harness not claude)\n' "$label"; return
  fi
  json=$(settings_json "$log")
  printf '%-22s jq -e .autoCompactWindow => %s\n' "$label" "$(printf '%s' "$json" | jq -e '.autoCompactWindow' 2>&1)"
}

fail=0
# 1. crewmate (ship spawn)
rec=$(make_spawn_case crew claude crew-z1); read_case_record "$rec"
out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" crew-z1 "$PROJ_DIR"); echo "spawn crewmate: $out" | head -1
report crewmate "$LAUNCH_LOG"; [ "$(settings_json "$LAUNCH_LOG" | jq -r .autoCompactWindow)" = 220000 ] || fail=1

# 2. scout
rec=$(make_spawn_case scout claude scout-z2); read_case_record "$rec"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" scout-z2 "$PROJ_DIR" --scout); echo "spawn scout: $out" | head -1
report scout "$LAUNCH_LOG"; [ "$(settings_json "$LAUNCH_LOG" | jq -r .autoCompactWindow)" = 220000 ] || fail=1

# 3. persistent secondmate (claude harness)
rec=$(make_spawn_case sm claude sm-z3); read_case_record "$rec"
sm="$CASE_DIR/secondmate-home"; make_seeded_secondmate_home "$sm" sm-z3
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" sm-z3 "$sm" --secondmate); echo "spawn secondmate: $out" | head -1
report secondmate "$LAUNCH_LOG"; [ "$(settings_json "$LAUNCH_LOG" | jq -r .autoCompactWindow)" = 220000 ] || fail=1

# 4. boundary: non-claude harness (codex) must not receive the claude settings
rec=$(make_spawn_case codex codex codex-z4); read_case_record "$rec"
out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" codex-z4 "$PROJ_DIR" --harness codex); echo "spawn codex: $out" | head -1
report "codex crewmate" "$LAUNCH_LOG"; grep -q autoCompactWindow "$LAUNCH_LOG" && fail=1
echo "codex launch line: $(cat "$LAUNCH_LOG" | cut -c1-160)"

# 5. every claude --settings JSON is one object with the full expected key set
echo "crewmate settings keys: $(settings_json "$TMP_ROOT/crew/launch.log" | jq -c 'keys')"
rm -rf "$TMP_ROOT"
[ $fail -eq 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
