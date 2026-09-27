#!/usr/bin/env bash
# Default-on live guard for the durable task-slot lease against the REAL
# treehouse binary (the pin bin/fm-install-treehouse.sh installs in CI).
#
# Two vendor facts carry the lease mechanism, and no fixture can establish
# either - tests/fm-spawn-slot-lease.test.sh can only assert against a fake that
# mirrors them:
#
#   1. the shape of `treehouse status --json`, which bin/fm-teardown.sh parses to
#      prove a pool slot's lease belongs to the task being torn down before
#      returning it (top-level array; per slot `path`, `status == "leased"`,
#      `lease_holder`);
#   2. what treehouse does with a slot whose checkout has been removed outside
#      Firstmate - measured here as: it drops the slot from `status --json`
#      entirely and reissues that same slot path to the next `get --lease`, so a
#      pruned copy leaves no reservation outliving its task.
#
# Fact 2 is why teardown's absent-copy path can only ever warn about a lease it
# cannot prove: on this treehouse there is nothing left to prove ownership from.
# If a later release starts holding a missing slot reserved, this guard fails and
# says so, which is the signal that path has to start freeing leases for real.
#
# It fails naming the treehouse version whenever either fact drifts. No model
# token is spent, so the shared live gate runs it wherever treehouse is
# installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_SPAWN_SLOT_LEASE_LIVE_E2E treehouse jq

TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-lease-live)

TREEHOUSE_VERSION=$(treehouse --version 2>/dev/null | head -1)
[ -n "$TREEHOUSE_VERSION" ] || TREEHOUSE_VERSION=unknown

PROJECT_DIR=
POOL_DIR=

# The real treehouse, resolving its pool from the project and TREEHOUSE_ROOT.
real_treehouse() {
  ( cd "$PROJECT_DIR" && TREEHOUSE_ROOT="$POOL_DIR" treehouse "$@" )
}

# The lease holder the real `status --json` reports for <path>, read with the
# same filter bin/fm-teardown.sh proves ownership with. Empty when that path is
# not reported leased at all.
status_lease_holder() {  # <path>
  real_treehouse status --json 2>/dev/null | jq -r --arg path "$1" \
    '[.[] | select(.path == $path and .status == "leased")][0].lease_holder // ""'
}

status_reports_slot() {  # <path>
  real_treehouse status --json 2>/dev/null | jq -e --arg path "$1" \
    '[.[] | select(.path == $path)] | length > 0' >/dev/null
}

# A real spawn's lease is reported for its own task id, and the real teardown
# frees it: the status shape teardown's ownership proof parses is the shape this
# treehouse prints.
test_real_lease_is_reported_for_its_task_and_freed_by_teardown() {
  local case_dir home fakebin slot out status holder
  case_dir="$TMP_ROOT/landed"
  home="$case_dir/home"
  PROJECT_DIR="$case_dir/project"
  POOL_DIR="$case_dir/pool"
  local id=lease-live-r1

  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$POOL_DIR"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$PROJECT_DIR"

  slot=$(real_treehouse get --lease --lease-holder "$id" 2>/dev/null) || \
    fail "treehouse $TREEHOUSE_VERSION could not lease a pool slot"
  [ -n "$slot" ] && [ -d "$slot" ] || \
    fail "treehouse $TREEHOUSE_VERSION leased '${slot:-<empty>}', which is not a directory"

  holder=$(status_lease_holder "$slot")
  [ "$holder" = "$id" ] || \
    fail "treehouse $TREEHOUSE_VERSION status --json does not report $slot leased to $id (read '$holder'): $(real_treehouse status --json 2>&1)"

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
    TREEHOUSE_ROOT="$POOL_DIR" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "teardown of a clean scout should succeed"$'\n'"$out"
  holder=$(status_lease_holder "$slot")
  [ -z "$holder" ] || \
    fail "teardown left the real lease on $slot held for '$holder' (treehouse $TREEHOUSE_VERSION)"$'\n'"$out"
  status_reports_slot "$slot" || \
    fail "teardown did not leave $slot in the pool (treehouse $TREEHOUSE_VERSION): $(real_treehouse status --json 2>&1)"
  pass "a real treehouse lease is reported for its own task and freed by teardown (treehouse $TREEHOUSE_VERSION)"
}

# The fact teardown's absent-copy path depends on: a slot whose checkout has
# been removed is no longer reported at all, and the next lease is handed that
# same slot path - so no reservation outlives the task whose copy was pruned.
test_real_treehouse_reissues_a_slot_whose_copy_was_removed() {
  local case_dir slot reissued holder
  case_dir="$TMP_ROOT/pruned"
  PROJECT_DIR="$case_dir/project"
  POOL_DIR="$case_dir/pool"

  mkdir -p "$POOL_DIR"
  fm_git_init_commit "$PROJECT_DIR"

  slot=$(real_treehouse get --lease --lease-holder lease-live-pruned-r1 2>/dev/null) || \
    fail "treehouse $TREEHOUSE_VERSION could not lease a pool slot"
  [ -n "$slot" ] && [ -d "$slot" ] || \
    fail "treehouse $TREEHOUSE_VERSION leased '${slot:-<empty>}', which is not a directory"

  rm -rf "$slot"

  if status_reports_slot "$slot"; then
    holder=$(status_lease_holder "$slot")
    [ -z "$holder" ] || \
      fail "treehouse $TREEHOUSE_VERSION now keeps $slot reserved for '$holder' after its copy was removed; teardown's absent-copy path must free that lease instead of only warning about it"
  fi

  reissued=$(real_treehouse get --lease --lease-holder lease-live-reissued-r1 2>/dev/null) || \
    fail "treehouse $TREEHOUSE_VERSION would not lease a slot after one copy was removed"
  [ "$reissued" = "$slot" ] || \
    fail "treehouse $TREEHOUSE_VERSION handed out '$reissued' instead of reissuing the pruned slot $slot"
  holder=$(status_lease_holder "$slot")
  [ "$holder" = lease-live-reissued-r1 ] || \
    fail "treehouse $TREEHOUSE_VERSION did not record the reissued lease on $slot (read '$holder')"
  pass "a pruned copy's slot is reissued by the real treehouse, so it reserves nothing for its old task (treehouse $TREEHOUSE_VERSION)"
}

test_real_lease_is_reported_for_its_task_and_freed_by_teardown
test_real_treehouse_reissues_a_slot_whose_copy_was_removed

echo "# all fm-spawn-slot-lease-live-e2e tests passed"
