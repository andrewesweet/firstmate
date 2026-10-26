#!/usr/bin/env bash
# Regression tests for the cwd a Herdr task tab is created in.
#
# Herdr persists the pane's live cwd and resumes shells there after restore.
# Both layouts must create task tabs in their leased copy and keep every
# subsequent shell-entry command in that copy. The flat workspace container
# remains keyed on the project.
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
  printf 'p%s' "$(jq '[.workspaces[].tabs[].pane_id | ltrimstr("p") | tonumber] | (max // -1) + 1' "$state")"
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
          [.workspaces[] | .workspace_id as $w | (.tabs // [])[] | select(.tab_id == $t) | . + {workspace_id: $w}]
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
          '[.workspaces[] | select(.workspace_id == $w) | (.tabs // [])[] | .tab_id | split(":")[-1] | tonumber] | max // 0' "$state")
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
      run)
        if [ -n "${FM_FAKE_FAIL_SEND:-}" ]; then
          sent=$(awk -F '\x1f' '$2 == "pane" && $3 == "run" { count++ } END { print count + 0 }' "$log")
          [ "$sent" != "$FM_FAKE_FAIL_SEND" ] || exit 1
        fi
        case "${args[3]:-}" in
          'cd -- '*)
            live=$(SHELL=pwd bash -c "${args[3]} && pwd") || exit 1
            commit "$(jq --arg p "${args[2]}" --arg cwd "$live" \
              '(.workspaces[].tabs[] | select(.pane_id == $p) | .foreground_cwd) = $cwd' "$state")"
            ;;
        esac
        exit 0
        ;;
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
        # A gone pane answers with the structured error object the real
        # binary sends, which fm_backend_herdr_pane_presence_state reads as
        # 'dead'; empty output would read as 'unknown' and make a confirmed
        # close look refused.
        hit=$(jq -r --arg p "$pid" --arg live "${FM_FAKE_PANE_PATH:-}" '
          [.workspaces[] | . as $ws | (.tabs // [])[] | select(.pane_id == $p)
            | {result:{pane:{
                pane_id: .pane_id, tab_id: .tab_id, workspace_id: $ws.workspace_id,
                cwd: .cwd,
                foreground_cwd: (.foreground_cwd // (if $live == "" then .cwd else $live end))
              }}}]
          | if length == 1 then .[0] | tostring else empty end' "$state")
        if [ -n "$hit" ]; then
          printf '%s\n' "$hit"
        else
          printf '%s\n' '{"error":{"code":"pane_not_found"}}'
        fi
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
    # No agent is ever registered in the fake: every pane reads as a plain
    # shell (the shape a restore produces), via the structured agent_not_found
    # error object herdr 0.9.x sends.
    printf '%s\n' '{"error":{"code":"agent_not_found"}}'
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

# The emitted Herdr command stream is a public runtime boundary. The accepted
# restore contract requires every pane shell to remain in the task copy; a
# project-directory unwind would change the live cwd Herdr saves on shutdown.
assert_shell_stays_in_worktree() {
  local case_dir=$1 project=$2 wt=$3 label=$4 commands escaped_project
  commands=$(awk -F "$ESC" '$2 == "pane" && $3 == "run" { print $5 }' "$case_dir/herdr-calls.log")
  escaped_project=${project//\'/\'\\\'\'}
  assert_not_contains "$commands" "$project" "$label: a typed send moved the pane into the project"
  assert_not_contains "$commands" "$escaped_project" "$label: a typed send moved the pane into the project"
  assert_contains "$commands" "${wt//\'/\'\\\'\'}" "$label: no worktree entry was sent"
}

# --- case 1: ordinary flat layout (presentation off) ------------------------

IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR <<EOF
$(make_herdr_tab_cwd_case "flat's space" off)
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
assert_shell_stays_in_worktree "$CASE_DIR" "$PROJECT_DIR" "$WT_DIR" "flat layout"
assert_not_contains "$OUT" 'was not returned after an aborted spawn' "successful flat spawn keeps its published lease"

# The per-home workspace container stays keyed on the project: the flat
# layout's workspace create runs in the project directory, never the worktree.
WS_CREATE_LINE=$(grep -F $'\x1f''workspace'$'\x1f''create' "$CASE_DIR/herdr-calls.log" | head -1)
[ "$(line_flag_value "$WS_CREATE_LINE" --cwd)" = "$PROJECT_DIR" ] || {
  fail "flat layout: per-home workspace container was not created in the project '$PROJECT_DIR':
$WS_CREATE_LINE"
}

pass "flat layout: task tab created in the task worktree, container in the project"

for ENDPOINT_STATE in restored drifted missing; do
  jq 'del(.workspaces[].tabs[].foreground_cwd)' "$CASE_DIR/herdr-state.json" > "$CASE_DIR/herdr-state.tmp"
  mv "$CASE_DIR/herdr-state.tmp" "$CASE_DIR/herdr-state.json"
  if [ "$ENDPOINT_STATE" = missing ]; then
    jq '.workspaces[].tabs = []' "$CASE_DIR/herdr-state.json" > "$CASE_DIR/herdr-state.tmp"
    mv "$CASE_DIR/herdr-state.tmp" "$CASE_DIR/herdr-state.json"
  fi
  : > "$CASE_DIR/herdr-calls.log"
  PANE_CWD=$WT_DIR
  [ "$ENDPOINT_STATE" != drifted ] || PANE_CWD=$PROJECT_DIR
  OUT=$(run_spawn_herdr "$HOME_DIR" "$PANE_CWD" "$FAKEBIN_DIR" \
    flat-task --relaunch --harness 'sh -c "while :; do sleep 60; done"')
  SPAWN_STATUS=$?
  [ "$SPAWN_STATUS" -eq 0 ] || fail "$ENDPOINT_STATE endpoint relaunch failed: $OUT"
  assert_shell_stays_in_worktree "$CASE_DIR" "$PROJECT_DIR" "$WT_DIR" "$ENDPOINT_STATE relaunch"
  if [ "$ENDPOINT_STATE" = missing ]; then
    assert_tab_create_cwd "$CASE_DIR" "$WT_DIR" "missing endpoint rebind"
  else
    [ -z "$(herdr_tab_create_lines "$CASE_DIR")" ] || fail "$ENDPOINT_STATE relaunch created another endpoint"
  fi
  pass "$ENDPOINT_STATE relaunch: pane shells stay in the task worktree"
done

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
# just its task tab: the workspace shell also needs to keep its live cwd there
# for a server restore.
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
assert_shell_stays_in_worktree "$CASE_DIR" "$PROJECT_DIR" "$WT_DIR" "projection layout"
assert_not_contains "$OUT" 'was not returned after an aborted spawn' "successful projection spawn keeps its published lease"

pass "projection layout: projected workspace and task tab both created in the task worktree"

OLD_PANE=$(meta_field "$HOME_DIR" proj-task herdr_pane_id)
OLD_WORKSPACE=$(meta_field "$HOME_DIR" proj-task herdr_workspace_id)
: > "$CASE_DIR/herdr-calls.log"
OUT=$(run_spawn_herdr "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  proj-task "$PROJECT_DIR" 'sh -c "while :; do sleep 60; done"' \
  --backend herdr --mode no-mistakes --yolo off)
SPAWN_STATUS=$?
[ "$SPAWN_STATUS" -eq 0 ] || fail "projection reclaim failed: $OUT"
[ "$(meta_field "$HOME_DIR" proj-task herdr_workspace_id)" = "$OLD_WORKSPACE" ] ||
  fail "projection reclaim must keep the existing projected workspace"
[ "$(meta_field "$HOME_DIR" proj-task herdr_pane_id)" != "$OLD_PANE" ] ||
  fail "projection reclaim must replace the restored pane"
assert_tab_create_cwd "$CASE_DIR" "$WT_DIR" "projection reclaim"
assert_shell_stays_in_worktree "$CASE_DIR" "$PROJECT_DIR" "$WT_DIR" "projection reclaim"
pass "projection reclaim: replacement tab and pane shells stay in the task worktree"

for GET_STATUS in 0 1; do
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR <<EOF
$(make_herdr_tab_cwd_case "prior-record-$GET_STATUS" on)
EOF
  export FM_HERDR_FAKE_STATE="$CASE_DIR/herdr-state.json" \
    FM_HERDR_LOG="$CASE_DIR/herdr-calls.log" \
    FM_HERDR_FAKE_SOCKET="$TMP_ROOT/herdr-sock/default.sock" \
    FM_FAKE_LEASE_FILE="$CASE_DIR/leases" FM_FAKE_GET_STATUS="$GET_STATUS"
  fm_test_spawn_brief "$HOME_DIR" prior-task
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$CASE_DIR/prior-copy" HEAD
  printf 'worktree=%s\nproject=%s\nbackend=herdr\n' "$CASE_DIR/prior-copy" "$PROJECT_DIR" \
    > "$HOME_DIR/state/prior-task.meta"
  cp "$HOME_DIR/state/prior-task.meta" "$CASE_DIR/prior.meta"
  touch "$HOME_DIR/state/prior-task.herdr-presentation"
  printf '%s\n' "$CASE_DIR/prior-copy" > "$FM_FAKE_LEASE_FILE"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  get)
    printf '%s\n' "$FM_FAKE_PANE_PATH" >> "$FM_FAKE_LEASE_FILE"
    printf '%s\n' "$FM_FAKE_PANE_PATH"
    exit "$FM_FAKE_GET_STATUS"
    ;;
  return)
    [ "${2:-}" = --force ] || exit 1
    awk -v target="$3" '$0 != target' "$FM_FAKE_LEASE_FILE" > "$FM_FAKE_LEASE_FILE.tmp"
    mv "$FM_FAKE_LEASE_FILE.tmp" "$FM_FAKE_LEASE_FILE"
    ;;
esac
SH
  OUT=$(run_spawn_herdr "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    prior-task "$PROJECT_DIR" 'sh -c "while :; do sleep 60; done"' \
    --backend herdr --mode no-mistakes --yolo off)
  SPAWN_STATUS=$?
  [ "$SPAWN_STATUS" -ne 0 ] || fail "prior-record spawn unexpectedly succeeded"
  if [ "$GET_STATUS" = 0 ]; then
    assert_contains "$OUT" 'existing metadata for prior-task has no endpoint' "refusal occurs after acquiring the new lease"
  else
    assert_contains "$OUT" 'could not lease a Treehouse pool slot' "failed get reports its refusal"
  fi
  [ "$(cat "$FM_FAKE_LEASE_FILE")" = "$CASE_DIR/prior-copy" ] ||
    fail "refused spawn must return only its new lease, preserving the prior copy's lease: $OUT"
  cmp -s "$CASE_DIR/prior.meta" "$HOME_DIR/state/prior-task.meta" ||
    fail "refused spawn changed the prior task record"
  pass "get exit $GET_STATUS: aborted spawn returns its new lease and preserves the prior record and lease"
done
unset FM_FAKE_LEASE_FILE FM_FAKE_GET_STATUS

for FAIL_SEND in 1; do
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR <<EOF
$(make_herdr_tab_cwd_case "failed-send-$FAIL_SEND" off)
EOF
  export FM_HERDR_FAKE_STATE="$CASE_DIR/herdr-state.json" \
    FM_HERDR_LOG="$CASE_DIR/herdr-calls.log" \
    FM_HERDR_FAKE_SOCKET="$TMP_ROOT/herdr-sock/default.sock" \
    FM_FAKE_FAIL_SEND="$FAIL_SEND" FM_FAKE_LEASE_FILE="$CASE_DIR/lease"
  fm_test_spawn_brief "$HOME_DIR" failed-send-task
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  get) printf '%s\n' "$FM_FAKE_PANE_PATH" | tee "$FM_FAKE_LEASE_FILE" ;;
  return)
    [ "${2:-}" = --force ] && [ "${3:-}" = "$(cat "$FM_FAKE_LEASE_FILE")" ] || exit 1
    rm "$FM_FAKE_LEASE_FILE"
    ;;
esac
SH
  OUT=$(run_spawn_herdr "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    failed-send-task "$PROJECT_DIR" 'sh -c "while :; do sleep 60; done"' \
    --backend herdr --mode no-mistakes --yolo off)
  SPAWN_STATUS=$?
  [ "$SPAWN_STATUS" -ne 0 ] || fail "typed-send failure $FAIL_SEND unexpectedly succeeded"
  assert_contains "$OUT" 'refusing to launch outside the copy holding its work' "typed-send failure refuses the worker launch"
  [ ! -e "$FM_FAKE_LEASE_FILE" ] || fail "typed-send failure $FAIL_SEND stranded its lease"
  [ ! -e "$HOME_DIR/state/failed-send-task.meta" ] || fail "typed-send failure published a task record"
  pass "typed-send failure $FAIL_SEND: spawn refuses and returns its lease"
done
unset FM_FAKE_FAIL_SEND FM_FAKE_LEASE_FILE
