#!/usr/bin/env bash
# Default-on live guard for the durable task-slot lease against the REAL
# treehouse binary - in CI the pin bin/fm-install-treehouse.sh installs into the
# portable-serial lane, locally whatever treehouse is on PATH.
#
# Two vendor facts carry the lease mechanism, and no fixture can establish
# either - tests/fm-spawn-slot-lease.test.sh can only assert against a fake that
# mirrors them:
#
#   1. a `treehouse get --lease --lease-holder <task>` reservation is durable and
#      named: treehouse's own pool state records the slot as leased to that task
#      until a return releases it, which is what makes a task's copy un-reissuable
#      while its record exists;
#   2. what teardown does about the reservation once that copy is removed
#      outside Firstmate - it must release it or name it for manual release,
#      never leave it silently, and the two pinned treehouse behaviours differ
#      underneath that property (v2.0.1 keeps a removed slot reserved, v2.3.0
#      stops reporting it and recycles the path).
#
# Both are read from treehouse's persisted pool state (<pool>/treehouse-state.json,
# the vendor's own serialized state file, which bin/fm-wake-lib.sh already treats
# as the marker of a managed pool), so the guard holds on every treehouse that
# leases at all - including the CI pin v2.0.1, whose `status` has no --json.
#
# Where the installed treehouse DOES offer `status --json`, the guard
# additionally pins the shape bin/fm-teardown.sh parses to prove an absent copy's
# lease belongs to the task being torn down (top-level array; per slot `path`,
# `status == "leased"`, `lease_holder`). On a treehouse without that flag the
# guard says so by name instead of asserting a contract that version has not got.
#
# Every slot this guard touches must lie inside its own throwaway pool: the pool
# root is pinned by a `treehouse.toml` committed in the throwaway repo (the only
# mechanism the CI pin honours - v2.0.1 has neither --root nor TREEHOUSE_ROOT),
# and each leased path is checked against that pool before any spawn, teardown or
# removal, so a treehouse that resolved some other pool cannot have an operator's
# live worktree deleted out from under it.
#
# It fails naming the treehouse version whenever a fact drifts. No model token is
# spent, so the shared live gate runs it wherever treehouse is installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# CI installs the pinned treehouse for this lane, so a missing binary there is a
# broken lane rather than a capability this host lacks: requesting the guard is
# what turns fm_live_gate's absent-tool skip into a hard failure. Local runs
# without treehouse keep the explicit capability skip.
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  : "${FM_SPAWN_SLOT_LEASE_LIVE_E2E:=1}"
fi

fm_live_gate default-on FM_SPAWN_SLOT_LEASE_LIVE_E2E treehouse jq

TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-lease-live)

TREEHOUSE_VERSION=$(treehouse --version 2>/dev/null | head -1)
[ -n "$TREEHOUSE_VERSION" ] || TREEHOUSE_VERSION=unknown

PROJECT_DIR=
POOL_DIR=

note() { printf '# %s\n' "$1"; }

# A throwaway repo whose committed treehouse.toml pins the pool this guard owns.
make_sandbox_project() {  # <project-dir> <pool-dir>
  local project=$1 pool=$2
  mkdir -p "$pool"
  fm_git_init_commit "$project"
  printf 'root = "%s"\n' "$pool" > "$project/treehouse.toml"
  git -C "$project" add treehouse.toml
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'pin the guard pool'
}

# The real treehouse, resolving its pool from the project's own treehouse.toml.
real_treehouse() {
  ( cd "$PROJECT_DIR" && treehouse "$@" )
}

# Refuse to act on any slot outside this guard's own pool: treehouse chose the
# path, and on a host where some other pool won it would be a live worktree.
require_sandboxed_slot() {  # <path>
  local slot=$1
  [ -n "$slot" ] || fail "treehouse $TREEHOUSE_VERSION leased no path"
  case "$slot" in
    "$POOL_DIR"/*) ;;
    *) fail "treehouse $TREEHOUSE_VERSION leased '$slot', outside this guard's pool $POOL_DIR; refusing to spawn, tear down or remove anything there" ;;
  esac
  [ -d "$slot" ] || fail "treehouse $TREEHOUSE_VERSION leased '$slot', which is not a directory"
}

# The lease holder treehouse's own persisted pool state records for <path>, or
# empty when that slot is not leased. <pool>/treehouse-state.json is treehouse's
# state file, the same artifact fm_treehouse_pool_slot reads to recognise a pool.
state_lease_holder() {  # <path>
  local slot=$1 state
  state="$(dirname "$(dirname "$slot")")/treehouse-state.json"
  [ -f "$state" ] || return 1
  jq -r --arg path "$slot" \
    '[(.worktrees // [])[] | select(.path == $path and (.leased // false))][0].lease_holder // ""' \
    "$state"
}

status_json_supported() {
  real_treehouse status --json >/dev/null 2>&1
}

# The holder `status --json` reports for <path>, read with the same filter
# bin/fm-teardown.sh proves absent-copy lease ownership with.
status_lease_holder() {  # <path>
  real_treehouse status --json 2>/dev/null | jq -r --arg path "$1" \
    '[.[] | select(.path == $path and .status == "leased")][0].lease_holder // ""'
}

# A real spawn's lease is recorded for its own task id, and the real teardown
# releases it.
test_real_lease_is_recorded_for_its_task_and_freed_by_teardown() {
  local case_dir home fakebin slot out status holder id=lease-live-r1
  case_dir="$TMP_ROOT/landed"
  home="$case_dir/home"
  PROJECT_DIR="$case_dir/project"
  POOL_DIR="$case_dir/pool"

  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  make_sandbox_project "$PROJECT_DIR" "$POOL_DIR"

  slot=$(real_treehouse get --lease --lease-holder "$id" 2>/dev/null) || \
    fail "treehouse $TREEHOUSE_VERSION could not lease a pool slot"
  require_sandboxed_slot "$slot"

  holder=$(state_lease_holder "$slot") || \
    fail "treehouse $TREEHOUSE_VERSION wrote no pool state beside $slot"
  [ "$holder" = "$id" ] || \
    fail "treehouse $TREEHOUSE_VERSION does not record $slot leased to $id (read '$holder')"

  if status_json_supported; then
    holder=$(status_lease_holder "$slot")
    [ "$holder" = "$id" ] || \
      fail "treehouse $TREEHOUSE_VERSION status --json does not report $slot leased to $id (read '$holder'): $(real_treehouse status --json 2>&1)"
  else
    note "treehouse $TREEHOUSE_VERSION has no 'status --json', so teardown's absent-copy ownership proof cannot be exercised against this build"
  fi

  # The record naming that slot, published by the real spawn. Only the spawn's
  # own allocation is faked, so it adopts the slot already leased above;
  # teardown then reads a real record against a real lease.
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$slot" "$fakebin" "$id" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 0 "$status" "the guard's scout spawn should launch"$'\n'"$out"
  assert_grep "worktree=$slot" "$home/state/$id.meta" \
    "the spawn did not record the leased slot"

  # Only the real treehouse answers teardown from here on.
  rm -f "$fakebin/treehouse"
  printf '# Scout findings\n\nNo changes needed.\n' > "$home/data/$id/report.md"
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "teardown of a clean scout should succeed"$'\n'"$out"
  holder=$(state_lease_holder "$slot") || \
    fail "the pool state beside $slot disappeared during teardown"
  [ -z "$holder" ] || \
    fail "teardown left the real treehouse $TREEHOUSE_VERSION lease on $slot held for '$holder'"$'\n'"$out"
  pass "a real treehouse lease is recorded for its own task and released by teardown (treehouse $TREEHOUSE_VERSION)"
}

# A pruned copy, on the real binary: teardown either releases the reservation
# treehouse still holds for the task or names it - never leaves it silently. The
# two pinned treehouse behaviours differ here (v2.0.1 keeps a removed slot
# reserved and has no `status --json` to prove ownership with, v2.3.0 stops
# reporting it), and both satisfy that one property, which is the intent's.
test_pruned_copy_lease_is_released_or_named_by_teardown() {
  local case_dir home fakebin slot out status holder id=lease-live-pruned-r1
  case_dir="$TMP_ROOT/pruned"
  home="$case_dir/home"
  PROJECT_DIR="$case_dir/project"
  POOL_DIR="$case_dir/pool"

  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  make_sandbox_project "$PROJECT_DIR" "$POOL_DIR"

  slot=$(real_treehouse get --lease --lease-holder "$id" 2>/dev/null) || \
    fail "treehouse $TREEHOUSE_VERSION could not lease a pool slot"
  require_sandboxed_slot "$slot"

  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$slot" "$fakebin" "$id" "$PROJECT_DIR" --scout)
  status=$?
  expect_code 0 "$status" "the guard's scout spawn should launch"$'\n'"$out"

  rm -f "$fakebin/treehouse"
  printf '# Scout findings\n\nNo changes needed.\n' > "$home/data/$id/report.md"
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null

  # Pruned outside Firstmate, so the claim beside the checkout is gone too and
  # the reservation is all that is left of the task's hold on the slot.
  rm -rf "$slot"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "teardown of a scout whose pool copy is gone should succeed"$'\n'"$out"
  [ ! -e "$home/state/$id.meta" ] || fail "teardown left the task record behind"$'\n'"$out"

  holder=$(state_lease_holder "$slot") || \
    fail "the pool state beside $slot disappeared during teardown"
  if [ -z "$holder" ]; then
    pass "teardown released the real treehouse reservation on a pruned copy (treehouse $TREEHOUSE_VERSION)"
    return 0
  fi
  [ "$holder" = "$id" ] || \
    fail "treehouse $TREEHOUSE_VERSION now reserves $slot for '$holder', which is not the torn-down task"
  assert_contains "$out" "$slot" \
    "teardown left treehouse $TREEHOUSE_VERSION reserving the pruned slot without naming it"
  assert_contains "$out" "treehouse return --force" \
    "teardown named the stranded reservation without the command that releases it"
  note "treehouse $TREEHOUSE_VERSION keeps a pruned slot reserved and offers no 'status --json' to prove ownership with, so teardown names the lease for manual release instead of freeing it"
  pass "a reservation teardown cannot free on a pruned copy is named, not left silent (treehouse $TREEHOUSE_VERSION)"
}

test_real_lease_is_recorded_for_its_task_and_freed_by_teardown
test_pruned_copy_lease_is_released_or_named_by_teardown

echo "# all fm-spawn-slot-lease-live-e2e tests passed"
