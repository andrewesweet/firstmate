#!/usr/bin/env bash
# Regression tests for the cwd a Herdr task tab is created in.
#
# Herdr persists each workspace's and tab's CREATION cwd and resumes workers
# in it after a server restore, so a task tab created in the project's primary
# checkout comes back as a plain shell sitting in that checkout - outside the
# task's isolated worktree. Both fresh spawn layouts therefore must hand the
# task's own worktree to the tab creation calls: the ordinary flat layout
# (`fm_backend_herdr_create_task`) and the default-on projection layout
# (`fm_backend_herdr_projection_create_task`). The per-home workspace
# container stays keyed on the project in the flat layout - only the task tab
# moves into the worktree.
#
# These tests drive the real bin/fm-spawn.sh against a stateful fake herdr
# client and the fake Treehouse pool lease, then assert the `--cwd` every
# `workspace create` and `tab create` call received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-tab-cwd)

# make_herdr_spawn_fakebin <dir> builds a spawn fakebin: the lease-aware
# treehouse stub, a noop sleep, and the stateful herdr client below.
# Echoes the fakebin path.
make_herdr_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_treehouse_lease "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Stateful recording herdr client. The session state lives as one JSON object
# in $FM_HERDR_FAKE_STATE:
#   {"workspaces":[{workspace_id,label,cwd,focused,active_tab_id,
#                   tabs:[{tab_id,label,cwd,focused,pane_id}]}]}
# Every invocation is logged to $FM_HERDR_LOG as unit-separated (\x1f) args,
# matching the existing herdr test-log format. Unknown commands exit 0
# silently. Read classifiers get the shapes the real herdr 0.9.x responses
# carry: `.result.tab.tab_id` plus `.result.root_pane.pane_id` on creates,
# `.result.pane.{pane_id,tab_id,workspace_id,cwd}` on pane get (with the live
# foreground cwd reported as $FM_FAKE_PANE_PATH, the way a leased pane reads
# after entering its copy), and `focused`/`active_tab_id` on workspace and tab
# reads for the projection focus snapshot.
set -u
state="${FM_HERDR_FAKE_STATE:?FM_HERDR_FAKE_STATE unset}"
log="${FM_HERDR_LOG:?FM_HERDR_LOG unset}"
mkdir -p "$(dirname "$state")"
[ -e "$state" ] || printf '{"workspaces":[]}' > "$state"
{
  for arg in "$@"; do
    printf '\x1f%s' "$arg"
  done
  printf '\n'
} >> "$log"

# Drop every trailing --session <name> pair.
args=()
prev=
for a in "$@"; do
  if [ "$prev" = --session ]; then
    prev=
    continue
  fi
  args+=("$a")
  prev=$a
done
[ "${#args[@]}" -gt 0 ] || exit 0

cmd=${args[0]}
sub=${args[1]:-}

flag_value() {  # <flag> -> FLAG_VALUE
  FLAG_VALUE=
  local i
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "$1" ] && [ "$((i + 1))" -lt "${#args[@]}" ]; then
      FLAG_VALUE=${args[$((i + 1))]}
      return 0
    fi
  done
  return 1
}

commit() {  # <updated-json>
  printf '%s' "$1" > "$state.tmp"
  mv "$state.tmp" "$state"
}

next_pane_id() {
  printf 'p%s' "$(jq '[.workspaces[].tabs | length] | add // 0' "$state")"
}

case "$cmd" in
  status)
    printf '{"client":{"version":"0.9.5","protocol":20},"server":{"running":true}}'
    exit 0
    ;;
  session)
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s"}]}' \
      "${FM_HERDR_FAKE_SOCKET:?FM_HERDR_FAKE_SOCKET unset}"
    exit 0
    ;;
  workspace)
    case "$sub" in
      list)
        jq '{result:{workspaces:[.workspaces[] | del(.tabs)]}}' "$state"
        exit 0
        ;;
      create)
        flag_value --cwd || exit 0
        cwd=$FLAG_VALUE
        flag_value --label || exit 0
        label=$FLAG_VALUE
        n=$(jq '[.workspaces[].tabs | length] | add // 0' "$state")
        id="w$n"
        pane=$(next_pane_id)
        commit "$(jq -n --arg id "$id" --arg label "$label" --arg cwd "$cwd" --arg pane "$pane" \
          --slurpfile prev "$state" '
          $prev[0] | .workspaces += [{
            workspace_id: $id, label: $label, cwd: $cwd, focused: false,
            active_tab_id: ($id + ":1"),
            tabs: [{tab_id: ($id + ":1"), label: "1", cwd: $cwd, focused: false, pane_id: $pane}]
          }]')"
        jq -n --arg id "$id" --arg label "$label" --arg pane "$pane" \
          '{result:{
              workspace_id: $id,
              workspace: {workspace_id: $id, label: $label},
              tab: {tab_id: ($id + ":1"), label: "1"},
              root_pane: {pane_id: $pane},
              pane: {pane_id: $pane}
            }}'
        exit 0
        ;;
    esac
    exit 0
    ;;
  tab)
    case "$sub" in
      list)
        flag_value --workspace || exit 0
        jq --arg w "$FLAG_VALUE" \
          '{result:{tabs:[.workspaces[] | select(.workspace_id == $w) | (.tabs // [])[]]}}' "$state"
        exit 0
        ;;
      get)
        tid=${args[2]:-}
        jq -r --arg t "$tid" '
          [.workspaces[] | (.tabs // [])[] | select(.tab_id == $t)]
          | if length == 1 then ({result:{tab:.[0]}} | tostring) else empty end' "$state"
        exit 0
        ;;
      focus)
        tid=${args[2]:-}
        commit "$(jq --arg t "$tid" '
          (.workspaces[] | .focused) = false
          | (.workspaces[].tabs[] | .focused) = false
          | (.workspaces[].tabs[] | select(.tab_id == $t) | .focused) = true
          | (.workspaces[] | select(any(.tabs[]; .tab_id == $t)) | .active_tab_id) = $t
          | (.workspaces[] | select(any(.tabs[]; .tab_id == $t)) | .focused) = true
        ' "$state")"
        exit 0
        ;;
      create)
        flag_value --workspace || exit 0
        wsid=$FLAG_VALUE
        flag_value --cwd || exit 0
        cwd=$FLAG_VALUE
        flag_value --label || exit 0
        label=$FLAG_VALUE
        seq=$(jq --arg w "$wsid" \
          '[.workspaces[] | select(.workspace_id == $w) | (.tabs // []) | length] | add // 0' "$state")
        [ -n "$seq" ] || exit 0
        tid="${wsid}:$((seq + 1))"
        pane=$(next_pane_id)
        commit "$(jq --arg w "$wsid" --arg t "$tid" --arg label "$label" --arg cwd "$cwd" --arg pane "$pane" '
          (.workspaces[] | select(.workspace_id == $w) | .tabs) +=
            [{tab_id: $t, label: $label, cwd: $cwd, focused: false, pane_id: $pane}]
        ' "$state")"
        jq -n --arg t "$tid" --arg label "$label" --arg pane "$pane" \
          '{result:{tab:{tab_id:$t, label:$label}, root_pane:{pane_id:$pane}, pane:{pane_id:$pane}}}'
        exit 0
        ;;
      close)
        tid=${args[2]:-}
        commit "$(jq --arg t "$tid" \
          '.workspaces = [.workspaces[] | .tabs = [(.tabs // [])[] | select(.tab_id != $t)]]' "$state")"
        exit 0
        ;;
    esac
    exit 0
    ;;
  pane)
    case "$sub" in
      list)
        flag_value --workspace || exit 0
        jq --arg w "$FLAG_VALUE" '
          {result:{panes:[.workspaces[] | select(.workspace_id == $w) | . as $ws | (.tabs // [])[]
            | {pane_id: .pane_id, tab_id: .tab_id, workspace_id: $ws.workspace_id,
               label: .label, focused: .focused}]}}' "$state"
        exit 0
        ;;
      get)
        pid=${args[2]:-}
        jq -r --arg p "$pid" --arg live "${FM_FAKE_PANE_PATH:-}" '
          [.workspaces[] | . as $ws | (.tabs // [])[] | select(.pane_id == $p)
            | {result:{pane:{
                pane_id: .pane_id, tab_id: .tab_id, workspace_id: $ws.workspace_id,
                cwd: .cwd,
                foreground_cwd: (if $live == "" then .cwd else $live end)
              }}}]
          | if length == 1 then .[0] | tostring else empty end' "$state"
        exit 0
        ;;
      close)
        pid=${args[2]:-}
        commit "$(jq --arg p "$pid" \
          '.workspaces = [.workspaces[] | .tabs = [(.tabs // [])[] | select(.pane_id != $p)]]' "$state")"
        exit 0
        ;;
    esac
    exit 0
    ;;
  agent)
    printf '{"result":{"agent_not_found":true}}'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# make_herdr_tab_cwd_case <name> <presentation-preference> builds a home, an
# origin-less project with one detached linked worktree, and the fakebin; the
# preference file selects the spawn layout under test. Echoes
# <case>|<home>|<project>|<worktree>|<fakebin>.
# The detached worktree is also FM_FAKE_PANE_PATH: the treehouse stub leases
# it, and the fake herdr panes report it as their live foreground cwd the way
# a real leased pane reads after entering its copy.
make_herdr_tab_cwd_case() {
  local name=$1 pref=$2 case_dir home project wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_herdr_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$TMP_ROOT/herdr-sock"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '%s\n' "$pref" > "$home/config/herdr-presentation-spaces"
  touch "$home/state/.last-watcher-beat" "$TMP_ROOT/herdr-sock/default.sock"

  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet --detach "$wt" HEAD

  printf '%s\n' "$case_dir|$home|$project|$wt|$fakebin"
}

herdr_tab_create_lines() {  # <case-dir>
  grep -F $'\x1f''tab'$'\x1f''create' "$1/herdr-calls.log" 2>/dev/null
}

herdr_projected_workspace_create_line() {  # <case-dir>
  local pattern
  pattern=$'\x1f''workspace'$'\x1f''create'
  grep -F "$pattern" "$1/herdr-calls.log" 2>/dev/null \
    | grep -F $'\x1f''--label'$'\x1f''└ '
}

# line_flag_value <line> <flag>
# Order-independent: prints the value following <flag> in the unit-separated
# call record.
ESC=$(printf '\x1f')
line_flag_value() {  # <line> <flag>
  printf '%s\n' "$1" | awk -F "$ESC" -v flag="$2" \
    '{ for (i = 1; i < NF; i += 1) if ($i == flag) { print $(i + 1); exit } }'
}

# run_spawn_herdr <args...>: fm_test_run_spawn with this session's own real
# herdr ancestry scrubbed, so the fake session is the only herdr identity the
# spawn can inherit.
run_spawn_herdr() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  (
    unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_SESSION
    fm_test_run_spawn "$home" "$pane" "$fakebin" "$@"
  )
}

meta_field() {  # <home> <id> <field>
  grep "^$3=" "$1/state/$2.meta" 2>/dev/null | cut -d= -f2-
}

assert_tab_create_cwd() {  # <case-dir> <worktree> <label>
  local case_dir=$1 wt=$2 label=$3 lines cwd
  lines=$(herdr_tab_create_lines "$case_dir") || fail "$label: no herdr tab create call was logged"
  [ "$(printf '%s\n' "$lines" | wc -l)" -eq 1 ] || {
    fail "$label: expected exactly one tab create call, got:
$lines"
  }
  cwd=$(line_flag_value "$lines" --cwd)
  [ "$cwd" = "$wt" ] || {
    fail "$label: task tab was created with cwd '$cwd', expected the worktree '$wt'
$lines"
  }
}

assert_no_tab_create_at() {  # <case-dir> <cwd> <label>
  local case_dir=$1 bad=$2 label=$3 pattern
  pattern=$(printf '\x1f--cwd\x1f%s' "$bad")
  if herdr_tab_create_lines "$case_dir" | grep -F "$pattern" >/dev/null 2>&1; then
    fail "$label: a task tab was created with the forbidden cwd '$bad'"
  fi
}

# --- case 1: ordinary flat layout (presentation off) ------------------------

IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR <<EOF
$(make_herdr_tab_cwd_case flat off)
EOF
export FM_HERDR_FAKE_STATE="$CASE_DIR/herdr-state.json" \
  FM_HERDR_LOG="$CASE_DIR/herdr-calls.log" \
  FM_HERDR_FAKE_SOCKET="$TMP_ROOT/herdr-sock/default.sock"

fm_test_spawn_brief "$HOME_DIR" flat-task

OUT=$(run_spawn_herdr "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  flat-task "$PROJECT_DIR" 'sh -c "while :; do sleep 60; done"' \
  --backend herdr --mode no-mistakes --yolo off)
SPAWN_STATUS=$?
[ "$SPAWN_STATUS" -eq 0 ] || fail "flat spawn failed with status $SPAWN_STATUS:
$OUT"

[ "$(meta_field "$HOME_DIR" flat-task worktree)" = "$WT_DIR" ] || {
  fail "flat spawn did not record worktree=$WT_DIR in its metadata:
$(cat "$HOME_DIR/state/flat-task.meta" 2>/dev/null)"
}

assert_tab_create_cwd "$CASE_DIR" "$WT_DIR" "flat layout"
assert_no_tab_create_at "$CASE_DIR" "$PROJECT_DIR" "flat layout"

# The per-home workspace container stays keyed on the project: the flat
# layout's workspace create runs in the project directory, never the worktree.
WS_CREATE_LINE=$(grep -F $'\x1f''workspace'$'\x1f''create' "$CASE_DIR/herdr-calls.log" | head -1)
[ "$(line_flag_value "$WS_CREATE_LINE" --cwd)" = "$PROJECT_DIR" ] || {
  fail "flat layout: per-home workspace container was not created in the project '$PROJECT_DIR':
$WS_CREATE_LINE"
}

pass "flat layout: task tab created in the task worktree, container in the project"

# --- case 2: projection layout (presentation on) -----------------------------

IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR <<EOF
$(make_herdr_tab_cwd_case proj on)
EOF
export FM_HERDR_FAKE_STATE="$CASE_DIR/herdr-state.json" \
  FM_HERDR_LOG="$CASE_DIR/herdr-calls.log" \
  FM_HERDR_FAKE_SOCKET="$TMP_ROOT/herdr-sock/default.sock"

# The projection binds its child under this home's exact parent workspace, so
# seed the persistent parent the launcher's label lookup resolves.
printf '{"workspaces":[{"workspace_id":"w0","label":"firstmate","cwd":"%s","focused":true,"active_tab_id":"w0:1","tabs":[{"tab_id":"w0:1","label":"1","cwd":"%s","focused":true,"pane_id":"p0"}]}]}' \
  "$PROJECT_DIR" "$PROJECT_DIR" > "$CASE_DIR/herdr-state.json"

fm_test_spawn_brief "$HOME_DIR" proj-task

OUT=$(run_spawn_herdr "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  proj-task "$PROJECT_DIR" 'sh -c "while :; do sleep 60; done"' \
  --backend herdr --mode no-mistakes --yolo off)
SPAWN_STATUS=$?
[ "$SPAWN_STATUS" -eq 0 ] || fail "projection spawn failed with status $SPAWN_STATUS:
$OUT"

[ "$(meta_field "$HOME_DIR" proj-task worktree)" = "$WT_DIR" ] || {
  fail "projection spawn did not record worktree=$WT_DIR in its metadata:
$(cat "$HOME_DIR/state/proj-task.meta" 2>/dev/null)"
}

# The projected child workspace itself must be created in the worktree, not
# just its task tab: a server restore resumes the workspace shell from the
# workspace's own creation cwd.
PROJ_WS_LINE=$(herdr_projected_workspace_create_line "$CASE_DIR") || {
  fail "projection layout: no projected workspace create call was logged
$(head -30 "$CASE_DIR/herdr-calls.log" 2>/dev/null)"
}
PROJ_WS_CWD=$(line_flag_value "$PROJ_WS_LINE" --cwd)
[ "$PROJ_WS_CWD" = "$WT_DIR" ] || {
  fail "projection layout: projected workspace was created with cwd '$PROJ_WS_CWD', expected the worktree '$WT_DIR'
$PROJ_WS_LINE"
}

assert_tab_create_cwd "$CASE_DIR" "$WT_DIR" "projection layout"
assert_no_tab_create_at "$CASE_DIR" "$PROJECT_DIR" "projection layout"

pass "projection layout: projected workspace and task tab both created in the task worktree"
