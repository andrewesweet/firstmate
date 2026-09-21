#!/usr/bin/env bash
# Evidence probe: a spawned worker must NOT receive COMPACT_ADVISER_DISABLE from
# Firstmate on any launch path (allowlist absent, allowlist enabled, and a relaunch).
# Drives the real bin/fm-spawn.sh against the shared fake pane, then EXECUTES the
# launch command the pane received with the harness replaced by an env probe.
set -u
ROOT_DIR=${1:?worktree root}
. "$ROOT_DIR/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-compact-adviser-enabled-probe)

probe_case() {  # <name> <allowlist:absent|enabled> [extra spawn args]
  local name=$1 allowlist=$2; shift 2
  local case_dir=$TMP_ROOT/$name home=$TMP_ROOT/$name/home proj=$TMP_ROOT/$name/project wt=$TMP_ROOT/$name/wt
  local fakebin launchlog=$case_dir/launch.log panelog=$case_dir/pane.log out seen
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$name-a1"
  [ "$allowlist" = enabled ] && : > "$home/config/launch-env-allowlist"
  : > "$launchlog"; : > "$panelog"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$name-a1" "$proj" --mode no-mistakes --yolo off)
  [ $? -eq 0 ] || { echo "SPAWN FAILED ($name): $out"; exit 1; }
  if [ "${1-}" = --relaunch ]; then
    : > "$launchlog"; : > "$panelog"
    out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$name-a1" --relaunch)
    [ $? -eq 0 ] || { echo "RELAUNCH FAILED ($name): $out"; exit 1; }
  fi
  # replace harness with env probe, then execute what the pane got
  printf '#!/bin/sh\nprintf "%%s\\n" "${COMPACT_ADVISER_DISABLE-unset}"\n' > "$fakebin/codex"; chmod +x "$fakebin/codex"
  local preamble; preamble=$(grep '^export ' "$panelog" || true)
  seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
    /bin/sh -c "$preamble
$(cat "$launchlog")")
  echo "case=$name allowlist=$allowlist pane-exports-of-switch=$(grep -c 'COMPACT_ADVISER_DISABLE' "$panelog" || true) launch-mentions-switch=$(grep -c 'COMPACT_ADVISER_DISABLE' "$launchlog" || true) agent-saw=$seen"
  [ "$seen" = unset ] || { echo "FAIL: agent started with COMPACT_ADVISER_DISABLE=$seen"; exit 1; }
}
probe_case ship-open absent
probe_case ship-filtered enabled

secondmate_case() {  # <setting>
  local setting=$1; local name=sm-$setting
  local case_dir=$TMP_ROOT/$name home=$TMP_ROOT/$name/home sm=$TMP_ROOT/$name/secondmate-home
  local fakebin launchlog=$case_dir/launch.log panelog=$case_dir/pane.log out seen
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$name"
  [ "$setting" = enabled ] && : > "$home/config/launch-env-allowlist"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$name" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$name" > "$sm/data/charter.md"
  : > "$launchlog"; : > "$panelog"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog"     fm_test_run_spawn "$home" "$sm" "$fakebin" "$name" "$sm" --secondmate)
  [ $? -eq 0 ] || { echo "SECONDMATE SPAWN FAILED ($name): $out"; exit 1; }
  printf '#!/bin/sh\nprintf "%%s\\n" "${COMPACT_ADVISER_DISABLE-unset}"\n' > "$fakebin/codex"; chmod +x "$fakebin/codex"
  local preamble; preamble=$(grep '^export ' "$panelog" || true)
  seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane     /bin/sh -c "$preamble
$(cat "$launchlog")")
  echo "case=$name allowlist=$setting pane-exports-of-switch=$(grep -c 'COMPACT_ADVISER_DISABLE' "$panelog" || true) launch-mentions-switch=$(grep -c 'COMPACT_ADVISER_DISABLE' "$launchlog" || true) agent-saw=$seen"
  [ "$seen" = unset ] || { echo "FAIL: secondmate started with COMPACT_ADVISER_DISABLE=$seen"; exit 1; }
}
secondmate_case absent
secondmate_case enabled

# fm-control.sh relaunch: rebuilds the launch through bin/fm-spawn.sh --relaunch.
relaunch_case() {  # <setting>
  local setting=$1; local id=relaunch-$setting-a1 dir=$TMP_ROOT/relaunch-$setting
  local home=$dir/home proj=$dir/proj wt=$dir/wt fb=$dir/fakebin out seen launch preamble
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake" "$fb" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  [ "$setting" = enabled ] && : > "$home/config/launch-env-allowlist"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac; done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in /exit|/quit) printf 'zsh' > "$D/command" ;; *'encode launch-brief'*) printf 'codex' > "$D/command" ;; esac
    else printf '%s\n' "$payload" >> "$D/keys"; fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;; *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"; chmod +x "$fb/tmux" "$fb/sleep"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fm_test_spawn_brief "$home" "$id"
  : > "$dir/fake/literal"; : > "$dir/fake/keys"
  printf 'codex' > "$dir/fake/command"; printf '%s\n' "fm-$id" > "$dir/fake/windows"; printf '%s' "$wt" > "$dir/fake/cwd"
  { echo "window=fmses:fm-$id"; echo "endpoint_task_id=$id"; echo "worktree=$wt"; echo "project=$proj"; echo "harness=codex"
    echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"; echo "tasktmp=$dir/tasktmp"; echo "model=default"; echo "effort=default"; } > "$home/state/$id.meta"
  out=$(env PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1     FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05     "$ROOT_DIR/bin/fm-control.sh" "$id" relaunch --note 'replacement continues the same task' 2>&1)
  [ $? -eq 0 ] || { echo "RELAUNCH FAILED ($id): $out"; exit 1; }
  launch=$(grep 'encode launch-brief' "$dir/fake/literal" | tail -1)
  [ -n "$launch" ] || { echo "RELAUNCH ($id): no replacement launch sent"; exit 1; }
  printf '#!/bin/sh\nprintf "%%s\\n" "${COMPACT_ADVISER_DISABLE-unset}"\n' > "$fb/codex"; chmod +x "$fb/codex"
  preamble=$(grep '^export ' "$dir/fake/keys" || true)
  seen=$(env -i HOME="$dir/user-home" PATH="$fb:$PATH" TERM=xterm TMUX=synthetic-pane /bin/sh -c "$preamble
$launch")
  echo "case=relaunch allowlist=$setting pane-exports-of-switch=$(grep -c 'COMPACT_ADVISER_DISABLE' "$dir/fake/keys" || true) launch-mentions-switch=$(printf '%s' "$launch" | grep -c 'COMPACT_ADVISER_DISABLE' || true) agent-saw=$seen"
  [ "$seen" = unset ] || { echo "FAIL: relaunched agent started with COMPACT_ADVISER_DISABLE=$seen"; exit 1; }
}
relaunch_case absent
relaunch_case enabled
echo "all launch paths leave the compact adviser enabled"
