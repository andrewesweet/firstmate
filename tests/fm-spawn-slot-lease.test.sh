#!/usr/bin/env bash
# Regression tests for durable Treehouse slot leases on task spawns.
#
# A Herdr server restart killed every worker and restored each session with its
# process cwd outside the task worktree. Treehouse judges a pool slot free when
# no process has its cwd inside it, so every occupied task slot read as
# available and one slot was leased a second time to a new scout while its
# original task still owned it. Spawns therefore hold a durable
# `treehouse get --lease` on their pooled copy for as long as the task exists,
# and teardown releases it after its landed-work checks pass.
#
# These tests drive the real spawn and teardown paths against a fake treehouse
# that implements pool lease semantics over a scratch pool (a leased slot is
# never handed out again until it is returned), proving through the scripts
# that a leased task slot is not reissued while its task exists, that teardown
# frees it for reuse, and that an aborted spawn does not strand a lease.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-lease)

# make_pool_fakebin <dir> builds a spawn fakebin whose treehouse implements a
# scratch pool with durable lease semantics. FM_FAKE_TREEHOUSE_POOL names the
# pool root at call time; <pool>/.fake-leases records "<slot> <holder>" lines
# and <pool>/.fake-calls logs every invocation. `get --lease` prints the first
# unleased slot's checkout and records the holder; a pool with no free slot
# fails. `return --force <path>` drops that slot's lease. Anything else exits 0.
make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(make_spawn_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
pool="${FM_FAKE_TREEHOUSE_POOL:?FM_FAKE_TREEHOUSE_POOL unset}"
leases="$pool/.fake-leases"
calls="$pool/.fake-calls"
mkdir -p "$pool"
: >> "$leases"
: >> "$calls"
printf 'treehouse %s\n' "$*" >> "$calls"
if [ "${1:-}" = get ]; then
  lease=0
  holder=""
  prev=""
  for a in "$@"; do
    [ "$a" = --lease ] && lease=1
    [ "$prev" = --lease-holder ] && holder=$a
    prev=$a
  done
  if [ "$lease" = 1 ]; then
    for slotdir in "$pool"/*/; do
      [ -d "$slotdir" ] || continue
      slot=$(basename "$slotdir")
      case "$slot" in .* ) continue ;; esac
      if ! grep -q "^$slot " "$leases" 2>/dev/null; then
        checkout=""
        for sub in "$slotdir"*/; do
          [ -d "$sub" ] || continue
          checkout=$sub
          break
        done
        [ -n "$checkout" ] || continue
        printf '%s %s\n' "$slot" "$holder" >> "$leases"
        ( cd "$checkout" && pwd -P )
        exit 0
      fi
    done
    echo "error: no free worktree in fake pool $pool" >&2
    exit 1
  fi
  exit 0
fi
if [ "${1:-}" = return ]; then
  target=""
  for a in "$@"; do
    case "$a" in -*) ;; *) target=$a ;; esac
  done
  slot=$(basename "$(dirname "$target")")
  grep -v "^$slot " "$leases" > "$leases.tmp" 2>/dev/null || true
  mv "$leases.tmp" "$leases"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_pool_case <name> <slots...> builds a home, an origin-less project, and a
# scratch pool with one detached linked worktree per slot name, plus the pool
# state file that marks them as managed Treehouse slots. Echoes
# <case>|<home>|<project>|<pool>|<fakebin>.
make_pool_case() {
  local name=$1 case_dir home project pool fakebin slot
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_pool_fakebin "$case_dir/fake")

  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"

  fm_git_init_commit "$project"
  mkdir -p "$pool"
  {
    printf '{"worktrees":['
    for slot in "$@"; do
      git -C "$project" worktree add --quiet --detach "$pool/$slot/project" HEAD
      printf '{"name":"%s","path":"%s"},' "$slot" "$pool/$slot/project"
    done
    printf '{"name":"_end","path":"none"}]}\n'
  } > "$pool/treehouse-state.json"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

read_pool_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_pool_spawn() {  # <id> <pane> [fm-spawn args...]
  local id=$1 pane=$2
  shift 2
  fm_test_spawn_brief "$HOME_DIR" "$id"
  FM_FAKE_TREEHOUSE_POOL="$POOL_DIR" \
    fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

run_pool_teardown() {  # <id>
  local id=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_TREEHOUSE_POOL="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1
}

leases_held() {
  grep -c . "$POOL_DIR/.fake-leases" 2>/dev/null || true
}

# A spawn leases its slot under its task id, and a second spawn is handed a
# different slot: the first task's copy is never reissued while it exists. A
# third spawn with no free slot refuses without publishing a record or
# stranding a lease.
test_leased_slot_is_not_reissued_while_task_exists() {
  local rec out status
  rec=$(make_pool_case leased 1 2)
  read_pool_record "$rec"

  out=$(run_pool_spawn lease-first-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "the first pool spawn should launch"$'\n'"$out"
  assert_contains "$out" "spawned lease-first-r1" "the first pool spawn did not report success"
  assert_grep "worktree=$POOL_DIR/1/project" "$HOME_DIR/state/lease-first-r1.meta" \
    "the first spawn did not publish its leased slot"
  grep -Fxq "1 lease-first-r1" "$POOL_DIR/.fake-leases" \
    || fail "the first spawn did not lease its slot under its task id: $(cat "$POOL_DIR/.fake-leases")"
  grep -Fxq -- "task=lease-first-r1" "$POOL_DIR/1/.fm-slot-owner" \
    || fail "the first spawn did not claim its leased slot"

  out=$(run_pool_spawn lease-second-r1 "$POOL_DIR/2/project" --scout)
  status=$?
  expect_code 0 "$status" "the second pool spawn should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR/2/project" "$HOME_DIR/state/lease-second-r1.meta" \
    "the second spawn did not publish the remaining free slot"
  grep -Fxq "2 lease-second-r1" "$POOL_DIR/.fake-leases" \
    || fail "the second spawn did not lease its slot under its task id"
  assert_grep "worktree=$POOL_DIR/1/project" "$HOME_DIR/state/lease-first-r1.meta" \
    "the second spawn moved the first task's record off its leased slot"
  grep -Fxq "1 lease-first-r1" "$POOL_DIR/.fake-leases" \
    || fail "the second spawn stole the first task's leased slot"

  out=$(run_pool_spawn lease-third-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn with no free pool slot launched anyway"$'\n'"$out"
  assert_contains "$out" "could not lease a Treehouse pool slot" \
    "the exhausted-pool spawn did not name the missing lease as the reason"
  [ ! -e "$HOME_DIR/state/lease-third-r1.meta" ] \
    || fail "the refused spawn published a task record"
  grep -Fq "lease-third-r1" "$POOL_DIR/.fake-leases" \
    && fail "the refused spawn stranded a lease: $(cat "$POOL_DIR/.fake-leases")"
  [ "$(leases_held)" = 2 ] \
    || fail "the refused spawn changed the pool leases: $(cat "$POOL_DIR/.fake-leases")"
  pass "a leased task slot is not reissued while its task exists, and an exhausted pool refuses cleanly"
}

# Tearing down a task returns its slot to the pool: the lease is dropped and
# the next spawn is handed that freed copy.
test_teardown_frees_the_lease_for_reuse() {
  local rec out status
  rec=$(make_pool_case freed 1 2)
  read_pool_record "$rec"

  out=$(run_pool_spawn lease-teardown-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "the spawn before teardown should launch"$'\n'"$out"
  grep -Fxq "1 lease-teardown-r1" "$POOL_DIR/.fake-leases" \
    || fail "the spawn did not lease its slot"
  printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/lease-teardown-r1/report.md"
  # Scouts refuse cleanup until their captain-call inventory is attested.
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete lease-teardown-r1 --none >/dev/null

  out=$(run_pool_teardown lease-teardown-r1)
  status=$?
  expect_code 0 "$status" "teardown of a clean scout should succeed"$'\n'"$out"
  grep -Fq "^1 " "$POOL_DIR/.fake-leases" \
    && fail "teardown left the task's slot leased: $(cat "$POOL_DIR/.fake-leases")"
  [ ! -e "$POOL_DIR/1/.fm-slot-owner" ] \
    || fail "teardown left the task's slot claim behind"
  grep -Fq "return --force $POOL_DIR/1/project" "$POOL_DIR/.fake-calls" \
    || fail "teardown did not return the leased copy: $(cat "$POOL_DIR/.fake-calls")"

  out=$(run_pool_spawn lease-reuse-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "a spawn after teardown should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR/1/project" "$HOME_DIR/state/lease-reuse-r1.meta" \
    "the next spawn was not handed the freed copy"
  grep -Fxq "1 lease-reuse-r1" "$POOL_DIR/.fake-leases" \
    || fail "the next spawn did not lease the freed copy under its own task id"
  pass "teardown frees the lease, and the next spawn reuses the freed copy"
}

# A spawn that fails after leasing - here on a dirty pooled copy - returns its
# lease and drops its claim, so no lease outlives a task that was never
# recorded.
test_aborted_spawn_returns_its_lease() {
  local rec out status
  rec=$(make_pool_case aborted 1)
  read_pool_record "$rec"
  printf 'keep this local work\n' > "$POOL_DIR/1/project/uncommitted.txt"

  out=$(run_pool_spawn lease-aborted-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a dirty leased copy"$'\n'"$out"
  assert_contains "$out" "is not clean" \
    "the aborted spawn did not refuse the dirty leased copy"
  [ ! -e "$HOME_DIR/state/lease-aborted-r1.meta" ] \
    || fail "the aborted spawn published a task record"
  [ ! -s "$POOL_DIR/.fake-leases" ] \
    || fail "the aborted spawn stranded a lease: $(cat "$POOL_DIR/.fake-leases")"
  [ ! -e "$POOL_DIR/1/.fm-slot-owner" ] && [ ! -L "$POOL_DIR/1/.fm-slot-owner" ] \
    || fail "the aborted spawn left a claim naming a task with no record"
  pass "an aborted spawn returns its lease and drops its claim"
}

# The endpoint cannot be told to enter the leased copy: the spawn refuses
# before any worker launches, and the lease does not outlive it.
test_failed_send_returns_its_lease() {
  local rec out status
  rec=$(make_pool_case sendfail 1)
  read_pool_record "$rec"

  out=$(FM_FAKE_TMUX_SEND_FAIL=1 run_pool_spawn lease-sendfail-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although its endpoint could not be told to cd"$'\n'"$out"
  assert_contains "$out" "could not be told to enter it" \
    "the spawn did not refuse when the cd could not be sent"
  [ ! -s "$POOL_DIR/.fake-leases" ] \
    || fail "a failed send stranded a lease: $(cat "$POOL_DIR/.fake-leases")"
  pass "a spawn whose endpoint cannot be told to cd returns its lease"
}

# The endpoint never reaches the leased copy: the settle wait times out, and
# the lease is returned rather than left naming a task with no record.
test_settle_timeout_returns_its_lease() {
  local rec out status
  rec=$(make_pool_case settletimeout 1 2)
  read_pool_record "$rec"

  # Slot 1 is leased, but the pane reports slot 2 - an isolated worktree that
  # is not the leased copy, so no read ever confirms the settle.
  out=$(run_pool_spawn lease-settle-r1 "$POOL_DIR/2/project" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although its endpoint never entered the leased copy"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree within 60s" \
    "the spawn did not refuse when its endpoint never reached the leased copy"
  [ ! -s "$POOL_DIR/.fake-leases" ] \
    || fail "a settle timeout stranded a lease: $(cat "$POOL_DIR/.fake-leases")"
  pass "a spawn whose endpoint never reaches the leased copy returns its lease"
}

test_leased_slot_is_not_reissued_while_task_exists
test_teardown_frees_the_lease_for_reuse
test_aborted_spawn_returns_its_lease
test_failed_send_returns_its_lease
test_settle_timeout_returns_its_lease

echo "# all fm-spawn-slot-lease tests passed"
