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
# fails. `return --force <path>` drops that slot's lease, and
# `--if-lease-holder <holder>` makes that release conditional on the recorded
# holder - the precondition every teardown return proves ownership with. It
# mirrors treehouse's own two refusals - identical on the v2.3.0 and v3.1.2
# lines Firstmate supports: `lease holder does not match`
# when another holder has it, `is not leased` when nothing does - and, like the
# vendor, refuses before doing any work, while a return that goes ahead cleans
# and resets the checkout the way `--force` documents.
# With FM_FAKE_TREEHOUSE_V3=1 it also models the treehouse 3.x dirty-return
# contract (measured against v3.1.2): a `return` WITHOUT --force of a dirty
# checkout refuses with exit 3 and the vendor's own wording, leaving the
# checkout and its lease untouched, while a --force return still cleans and
# frees the slot as on 2.3.x.
# tests/fm-spawn-slot-lease-live-e2e.test.sh exercises both against the real
# binary.
# Anything else exits 0.
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
        if [ "${FM_FAKE_TREEHOUSE_GET_FAIL_SILENT:-0}" = 1 ]; then
          echo "error: fake pool $pool: recorded the lease, then the checkout step failed" >&2
          exit 1
        fi
        ( cd "$checkout" && pwd -P )
        if [ "${FM_FAKE_TREEHOUSE_GET_FAIL_AFTER_LEASE:-0}" = 1 ]; then
          echo "error: fake pool $pool: printed the checkout, then the finalize step failed" >&2
          exit 1
        fi
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
  want_holder=""
  force=0
  prev=""
  shift
  for a in "$@"; do
    if [ "$prev" = --if-lease-holder ]; then
      want_holder=$a
    else
      case "$a" in
        --force) force=1 ;;
        -*) ;;
        *) target=$a ;;
      esac
    fi
    prev=$a
  done
  if [ "${FM_FAKE_TREEHOUSE_V3:-0}" = 1 ] && [ "$force" = 0 ] && [ -n "$target" ] && [ -d "$target" ] \
    && [ -n "$(git -C "$target" status --porcelain 2>/dev/null)" ]; then
    echo "worktree not returned: it has uncommitted changes and the confirmation could not be answered (stdin reached EOF); prune will not reclaim this slot. Use treehouse return --force '$target' to clean and return it" >&2
    exit 3
  fi
  slot=$(basename "$(dirname "$target")")
  holder=$(awk -v s="$slot" '$1 == s { print $2; exit }' "$leases")
  if [ -n "$want_holder" ] && [ -z "$holder" ]; then
    echo "failed to return worktree: lease precondition failed: worktree $target is not leased" >&2
    exit 1
  fi
  if [ -n "$want_holder" ] && [ "$want_holder" != "$holder" ]; then
    echo "failed to return worktree: lease precondition failed: lease holder does not match worktree $target" >&2
    exit 1
  fi
  if [ -n "$target" ] && [ -d "$target" ]; then
    git -C "$target" checkout -q --detach 2>/dev/null || true
    git -C "$target" reset -q --hard 2>/dev/null || true
    git -C "$target" clean -qfdx 2>/dev/null || true
  fi
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

run_pool_teardown() {  # <id> [fm-teardown args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_TREEHOUSE_POOL="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" "$@" 2>&1
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
  assert_not_contains "$out" "leased a Treehouse pool slot" \
    "the exhausted-pool spawn claimed a lease it never took"
  assert_contains "$out" "may have recorded a lease before it failed" \
    "the exhausted-pool spawn did not hedge whether its failed get left a lease"
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
  grep -q "^1 " "$POOL_DIR/.fake-leases" \
    && fail "teardown left the task's slot leased: $(cat "$POOL_DIR/.fake-leases")"
  [ ! -e "$POOL_DIR/1/.fm-slot-owner" ] \
    || fail "teardown left the task's slot claim behind"
  grep -Fq "return --force --if-lease-holder lease-teardown-r1 $POOL_DIR/1/project" \
    "$POOL_DIR/.fake-calls" \
    || fail "teardown did not return the leased copy under its own lease holder: $(cat "$POOL_DIR/.fake-calls")"

  out=$(run_pool_spawn lease-reuse-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "a spawn after teardown should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR/1/project" "$HOME_DIR/state/lease-reuse-r1.meta" \
    "the next spawn was not handed the freed copy"
  grep -Fxq "1 lease-reuse-r1" "$POOL_DIR/.fake-leases" \
    || fail "the next spawn did not lease the freed copy under its own task id"
  pass "teardown frees the lease, and the next spawn reuses the freed copy"
}

# A record from before task slots were leased: its pooled copy and slot-owner
# claim are this task's, but treehouse holds no lease on the slot. Teardown must
# still complete - an unleased slot is nobody else's, and the return is asking
# for a state the pool is already in.
test_teardown_completes_for_a_record_with_no_lease() {
  local rec out status
  rec=$(make_pool_case unleased 1 2)
  read_pool_record "$rec"

  out=$(run_pool_spawn lease-unleased-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "the spawn before the lease was dropped should launch"$'\n'"$out"
  printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/lease-unleased-r1/report.md"
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete lease-unleased-r1 --none >/dev/null

  # The shape a pre-lease record has: copy and claim intact, no lease recorded -
  # and a copy the dead task left work in, which only a real return cleans.
  : > "$POOL_DIR/.fake-leases"
  grep -Fxq -- "task=lease-unleased-r1" "$POOL_DIR/1/.fm-slot-owner" \
    || fail "the fixture lost the task's slot claim"
  printf 'DIRT\n' > "$POOL_DIR/1/project/dirty-file"
  git -C "$POOL_DIR/1/project" checkout -q -b leftover-branch

  out=$(run_pool_teardown lease-unleased-r1)
  status=$?
  expect_code 0 "$status" "teardown of a record whose slot carries no lease should succeed"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/lease-unleased-r1.meta" ] \
    || fail "teardown left the task record behind"$'\n'"$out"
  [ ! -e "$POOL_DIR/1/project/dirty-file" ] \
    || fail "teardown reported success without cleaning the returned copy"$'\n'"$out"
  [ "$(git -C "$POOL_DIR/1/project" rev-parse --abbrev-ref HEAD)" = HEAD ] \
    || fail "teardown reported success without resetting the returned copy off $(git -C "$POOL_DIR/1/project" rev-parse --abbrev-ref HEAD)"$'\n'"$out"
  grep -Fq "return --force $POOL_DIR/1/project" "$POOL_DIR/.fake-calls" \
    || fail "teardown never fell through to the plain return: $(cat "$POOL_DIR/.fake-calls")"

  out=$(run_pool_spawn lease-unleased-reuse-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "a spawn after teardown should be handed the freed copy"$'\n'"$out"
  grep -Fxq "1 lease-unleased-reuse-r1" "$POOL_DIR/.fake-leases" \
    || fail "the next spawn did not lease the freed copy: $(cat "$POOL_DIR/.fake-leases")"
  pass "teardown completes for a record whose slot carries no lease"
}

# The recorded pool copy is gone before teardown runs (an operator or external
# git maintenance removed or pruned it). Nothing else ever frees a durable
# lease, so teardown must still return the slot rather than reserve it for a
# task no record describes.
test_teardown_frees_the_lease_when_the_slot_directory_is_gone() {
  local rec out status
  rec=$(make_pool_case prunedslot 1 2)
  read_pool_record "$rec"

  out=$(run_pool_spawn lease-pruned-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "the spawn before the slot was pruned should launch"$'\n'"$out"
  grep -Fxq "1 lease-pruned-r1" "$POOL_DIR/.fake-leases" \
    || fail "the spawn did not lease its slot"
  printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/lease-pruned-r1/report.md"
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete lease-pruned-r1 --none >/dev/null

  rm -rf "$POOL_DIR/1/project"

  out=$(run_pool_teardown lease-pruned-r1)
  status=$?
  expect_code 0 "$status" "teardown of a scout whose pool copy is gone should succeed"$'\n'"$out"
  grep -q "^1 " "$POOL_DIR/.fake-leases" \
    && fail "teardown left the lease on a slot whose copy is gone: $(cat "$POOL_DIR/.fake-leases")"
  grep -Fq "return --force --if-lease-holder lease-pruned-r1 $POOL_DIR/1/project" \
    "$POOL_DIR/.fake-calls" \
    || fail "teardown did not return the leased copy under its own lease holder: $(cat "$POOL_DIR/.fake-calls")"
  [ ! -e "$HOME_DIR/state/lease-pruned-r1.meta" ] \
    || fail "teardown left the task record behind"
  pass "teardown frees the lease even when the slot's copy was removed before it ran"
}

# A slot whose copy is gone but whose lease treehouse reports for another task
# belongs to that task: teardown must leave it leased and name the holder,
# rather than hand a live task's slot back to the pool.
test_teardown_leaves_an_absent_copy_leased_to_another_task() {
  local rec out status
  rec=$(make_pool_case reassignedslot 1 2)
  read_pool_record "$rec"

  out=$(run_pool_spawn lease-notmine-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "the spawn before the slot was pruned should launch"$'\n'"$out"
  printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/lease-notmine-r1/report.md"
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete lease-notmine-r1 --none >/dev/null

  rm -rf "$POOL_DIR/1/project"
  # treehouse has since leased that slot to another task.
  printf '1 lease-otherowner-r1\n' > "$POOL_DIR/.fake-leases"

  out=$(run_pool_teardown lease-notmine-r1)
  status=$?
  expect_code 0 "$status" "teardown of a scout whose pool copy is gone should succeed"$'\n'"$out"
  grep -Fxq "1 lease-otherowner-r1" "$POOL_DIR/.fake-leases" \
    || fail "teardown dropped a lease held for another task: $(cat "$POOL_DIR/.fake-leases")"
  assert_contains "$out" "lease precondition failed" \
    "teardown did not report treehouse refusing to release another task's lease"
  assert_contains "$out" "$POOL_DIR/1/project" \
    "teardown did not name the slot whose lease it left alone"
  pass "teardown leaves an absent copy whose lease belongs to another task alone"
}

# A pooled copy gone from disk whose path the state file no longer lists - the
# slot was returned elsewhere, or the listing is stale - cannot be proved a
# pool slot any more, but the state file proves a pool still lives there. Its
# lease may still be held, so teardown must still warn with the command that
# frees the slot instead of dropping it silently.
test_teardown_warns_when_an_absent_copys_path_is_no_longer_listed() {
  local rec out status
  rec=$(make_pool_case unlisted 1 2)
  read_pool_record "$rec"

  out=$(run_pool_spawn lease-unlisted-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "the spawn before the copy went absent should launch"$'\n'"$out"
  printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/lease-unlisted-r1/report.md"
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete lease-unlisted-r1 --none >/dev/null

  # The copy is pruned and the state file no longer lists its path.
  rm -rf "$POOL_DIR/1/project"
  git -C "$PROJECT_DIR" worktree prune
  printf '{"worktrees":[{"name":"2","path":"%s"},{"name":"_end","path":"none"}]}\n' \
    "$POOL_DIR/2/project" > "$POOL_DIR/treehouse-state.json"

  out=$(run_pool_teardown lease-unlisted-r1)
  status=$?
  expect_code 0 "$status" "an unlisted absent copy must not block its own teardown"$'\n'"$out"
  assert_contains "$out" "its Treehouse slot lease was not returned" \
    "teardown did not warn that the absent copy's lease may still be held"
  assert_contains "$out" "treehouse return --force --if-lease-holder lease-unlisted-r1 $POOL_DIR/1/project" \
    "the warning did not name the manual release for the slot it could not prove"
  pass "teardown warns for an absent copy whose path the state file no longer lists"
}

# A record written before slot claims existed carries none to screen with, so
# only treehouse's own refusal on the return can reveal that the slot has become
# another task's: teardown must then refuse, leaving that copy on disk with its
# work, the lease with its holder and this record in place for a rerun, rather
# than freeing, resetting or deleting anything. (A record that does carry a
# claim naming another task never reaches any of those steps; that screen and
# the copy it protects are covered by tests/fm-teardown-endpoint-safety.test.sh.)
test_teardown_refuses_a_slot_leased_to_another_task() {
  local rec out status
  rec=$(make_pool_case unclaimedslot 1 2)
  read_pool_record "$rec"

  out=$(run_pool_spawn lease-unclaimed-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "the spawn before the slot was reassigned should launch"$'\n'"$out"
  printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/lease-unclaimed-r1/report.md"
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete lease-unclaimed-r1 --none >/dev/null

  # A pre-claim-era record: no claim to read, and the slot is now another live
  # task's, with that task's work in the checkout - its branch checked out and
  # its hook files in place.
  rm -f "$POOL_DIR/1/.fm-slot-owner"
  printf '1 lease-otherowner-r2\n' > "$POOL_DIR/.fake-leases"
  printf 'another live task is working here\n' > "$POOL_DIR/1/project/other-task-work.txt"
  git -C "$POOL_DIR/1/project" checkout -q -b other-task-branch
  mkdir -p "$POOL_DIR/1/project/.claude" "$POOL_DIR/1/project/.opencode/plugins"
  printf 'holder hooks\n' > "$POOL_DIR/1/project/.claude/settings.local.json"
  printf 'holder grok hook\n' > "$POOL_DIR/1/project/.fm-grok-turnend"
  printf 'holder turnend hook\n' > "$POOL_DIR/1/project/.opencode/plugins/fm-turn-end.js"

  out=$(run_pool_teardown lease-unclaimed-r1)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "teardown of a record whose slot is leased to another task should refuse"$'\n'"$out"
  assert_contains "$out" "lease-unclaimed-r1" \
    "the refusal did not name the task whose teardown was refused"
  assert_contains "$out" "$POOL_DIR/1/project" \
    "the refusal did not name the slot it left alone"
  [ -f "$POOL_DIR/1/project/other-task-work.txt" ] \
    || fail "the refused teardown deleted or reset a copy leased to another task"$'\n'"$out"
  [ -f "$POOL_DIR/1/project/.claude/settings.local.json" ] \
    || fail "the refused teardown removed hook files from a copy leased to another task"$'\n'"$out"
  [ -f "$POOL_DIR/1/project/.fm-grok-turnend" ] \
    || fail "the refused teardown removed a turnend hook from a copy leased to another task"$'\n'"$out"
  [ -f "$POOL_DIR/1/project/.opencode/plugins/fm-turn-end.js" ] \
    || fail "the refused teardown removed a turnend plugin from a copy leased to another task"$'\n'"$out"
  git -C "$POOL_DIR/1/project" rev-parse --verify -q other-task-branch >/dev/null \
    || fail "the refused teardown deleted the branch a copy leased to another task was working on"$'\n'"$out"
  [ "$(git -C "$POOL_DIR/1/project" rev-parse --abbrev-ref HEAD)" = "other-task-branch" ] \
    || fail "the refused teardown detached the checked-out branch of a copy leased to another task"$'\n'"$out"
  grep -Fxq "1 lease-otherowner-r2" "$POOL_DIR/.fake-leases" \
    || fail "the refused teardown dropped a lease held for another task: $(cat "$POOL_DIR/.fake-leases")"
  [ -e "$HOME_DIR/state/lease-unclaimed-r1.meta" ] \
    || fail "the refused teardown removed the task record it should keep for a rerun"$'\n'"$out"
  pass "teardown refuses a slot leased to another task, keeping its copy, lease and record"
}

# make_child_pool_case <name> wraps make_pool_case in a secondmate home holding
# one child scout record on pool slot 1, whose checkout has been removed. Echoes
# the same record as make_pool_case; the secondmate is torn down as `domain`.
make_child_pool_case() {  # <name> <child-id>
  local name=$1 child_id=$2 rec subhome
  rec=$(make_pool_case "$name" 1 2)
  read_pool_record "$rec"
  subhome="$CASE_DIR/subhome"
  mkdir -p "$subhome/state" "$HOME_DIR/data"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$HOME_DIR/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=project
EOF
  printf '%s\n' "- domain - design domain (home: $subhome; scope: design domain; projects: project; added 2026-06-22)" \
    > "$HOME_DIR/data/secondmates.md"
  cat > "$subhome/state/$child_id.meta" <<EOF
window=firstmate:fm-$child_id
worktree=$POOL_DIR/1/project
project=$PROJECT_DIR
harness=echo
kind=scout
mode=no-mistakes
yolo=off
EOF
  printf '1 %s\n' "$child_id" > "$POOL_DIR/.fake-leases"
  rm -rf "$POOL_DIR/1/project"
  printf '%s\n' "$rec"
}

# The same invariant one level down: a child record's lease is freed by the
# forced cleanup of its secondmate home even when the child's copy is gone.
test_child_cleanup_frees_the_lease_when_the_slot_directory_is_gone() {
  local out status
  make_child_pool_case childpruned lease-child-r1 >/dev/null

  out=$(run_pool_teardown domain --force)
  status=$?
  expect_code 0 "$status" "forced teardown of the secondmate home should succeed"$'\n'"$out"
  grep -q "^1 " "$POOL_DIR/.fake-leases" \
    && fail "child cleanup left the lease on a slot whose copy is gone: $(cat "$POOL_DIR/.fake-leases")"
  grep -Fq "return --force --if-lease-holder lease-child-r1 $POOL_DIR/1/project" \
    "$POOL_DIR/.fake-calls" \
    || fail "child cleanup did not return the child's leased copy under its own lease holder: $(cat "$POOL_DIR/.fake-calls")"
  pass "child cleanup frees a lease whose slot copy was removed"
}

# And a child slot whose lease treehouse reports for another task is left alone.
test_child_cleanup_leaves_an_absent_copy_leased_to_another_task() {
  local out status
  make_child_pool_case childnotmine lease-child-r2 >/dev/null
  printf '1 lease-otherowner-r2\n' > "$POOL_DIR/.fake-leases"

  out=$(run_pool_teardown domain --force)
  status=$?
  expect_code 0 "$status" "forced teardown of the secondmate home should succeed"$'\n'"$out"
  grep -Fxq "1 lease-otherowner-r2" "$POOL_DIR/.fake-leases" \
    || fail "child cleanup dropped a lease held for another task: $(cat "$POOL_DIR/.fake-leases")"
  assert_contains "$out" "lease precondition failed" \
    "child cleanup did not report treehouse refusing to release another task's lease"
  assert_contains "$out" "$POOL_DIR/1/project" \
    "child cleanup did not name the slot whose lease it left alone"
  pass "child cleanup leaves an absent copy whose lease belongs to another task alone"
}

# A spawn that refuses BECAUSE the pooled copy holds uncommitted work must not
# then clean, reset and return that copy: the work the refusal promised to leave
# untouched has to survive, with the lease left for a named manual return.
test_aborted_spawn_keeps_a_dirty_copys_work() {
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
  [ -f "$POOL_DIR/1/project/uncommitted.txt" ] \
    || fail "the aborted spawn discarded the uncommitted work its refusal left untouched"
  assert_contains "$out" "treehouse return --force $POOL_DIR/1/project" \
    "the aborted spawn did not name the manual return for the slot it kept"
  grep -Fxq "1 lease-aborted-r1" "$POOL_DIR/.fake-leases" \
    || fail "the aborted spawn returned the lease on a copy it left dirty: $(cat "$POOL_DIR/.fake-leases")"
  [ ! -e "$POOL_DIR/1/.fm-slot-owner" ] && [ ! -L "$POOL_DIR/1/.fm-slot-owner" ] \
    || fail "the aborted spawn left a claim naming a task with no record"
  pass "an aborted spawn leaves a dirty copy's work and names its manual return"
}

# A child slot still on disk whose lease treehouse reports for another task is
# that task's copy: the refusal must stop the retirement with that copy, its
# lease and the child record all still in place, never delete the copy.
test_child_cleanup_refuses_a_present_copy_leased_to_another_task() {
  local out status
  make_child_pool_case childpresent lease-child-r3 >/dev/null
  git -C "$PROJECT_DIR" worktree prune
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR/1/project" HEAD
  printf 'another live task is working here\n' > "$POOL_DIR/1/project/other-task-work.txt"
  printf '1 lease-otherowner-r3\n' > "$POOL_DIR/.fake-leases"
  # The child still claims the slot, so only treehouse's own refusal on the
  # return can reveal that the lease has moved on.
  printf 'task=lease-child-r3\nhome=%s\n' "$CASE_DIR/subhome" > "$POOL_DIR/1/.fm-slot-owner"

  out=$(run_pool_teardown domain --force)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "forced retirement should refuse while a child slot is leased to another task"$'\n'"$out"
  assert_contains "$out" "lease-child-r3" \
    "the refusal did not name the child whose slot it left alone"
  assert_contains "$out" "$POOL_DIR/1/project" \
    "the refusal did not name the slot it left alone"
  [ -f "$POOL_DIR/1/project/other-task-work.txt" ] \
    || fail "child cleanup deleted or reset a pool copy leased to another task"$'\n'"$out"
  grep -Fxq "1 lease-otherowner-r3" "$POOL_DIR/.fake-leases" \
    || fail "child cleanup dropped a lease held for another task: $(cat "$POOL_DIR/.fake-leases")"
  [ -e "$CASE_DIR/subhome/state/lease-child-r3.meta" ] \
    || fail "the refused retirement removed the child record it should keep for a rerun"$'\n'"$out"
  pass "child cleanup refuses a present copy whose lease belongs to another task"
}

# A child record from before slot claims existed, whose pooled copy is still on
# disk but leased to another live task, must be refused the same way - and the
# hook sweep a claimed child's cleanup runs must not fire before the one
# ownership proof, so the other task's copy keeps every one of its files.
test_child_cleanup_refuses_a_preclaim_present_copy_leased_to_another_task() {
  local out status
  make_child_pool_case childpre lease-child-r4 >/dev/null
  git -C "$PROJECT_DIR" worktree prune
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR/1/project" HEAD
  printf 'another live task is working here\n' > "$POOL_DIR/1/project/other-task-work.txt"
  mkdir -p "$POOL_DIR/1/project/.claude" "$POOL_DIR/1/project/.opencode/plugins"
  printf 'holder hooks\n' > "$POOL_DIR/1/project/.claude/settings.local.json"
  printf 'holder turnend hook\n' > "$POOL_DIR/1/project/.opencode/plugins/fm-turn-end.js"
  printf '1 lease-otherowner-r4\n' > "$POOL_DIR/.fake-leases"

  out=$(run_pool_teardown domain --force)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "forced retirement should refuse while a pre-claim child slot is leased to another task"$'\n'"$out"
  assert_contains "$out" "lease-child-r4" \
    "the refusal did not name the child whose slot it left alone"
  assert_contains "$out" "$POOL_DIR/1/project" \
    "the refusal did not name the slot it left alone"
  [ -f "$POOL_DIR/1/project/other-task-work.txt" ] \
    || fail "child cleanup deleted or reset a pre-claim pool copy leased to another task"$'\n'"$out"
  [ -f "$POOL_DIR/1/project/.claude/settings.local.json" ] \
    || fail "child cleanup removed hook files from a pre-claim copy leased to another task"$'\n'"$out"
  [ -f "$POOL_DIR/1/project/.opencode/plugins/fm-turn-end.js" ] \
    || fail "child cleanup removed a turnend plugin from a pre-claim copy leased to another task"$'\n'"$out"
  grep -Fxq "1 lease-otherowner-r4" "$POOL_DIR/.fake-leases" \
    || fail "child cleanup dropped a lease held for another task: $(cat "$POOL_DIR/.fake-leases")"
  [ -e "$CASE_DIR/subhome/state/lease-child-r4.meta" ] \
    || fail "the refused retirement removed the child record it should keep for a rerun"$'\n'"$out"
  pass "child cleanup refuses a pre-claim present copy whose lease belongs to another task"
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

# A `treehouse get --lease` that records the reservation and then fails must
# not strand it: the abort trap returns the slot the failed get printed.
test_a_failing_get_that_recorded_its_lease_returns_it() {
  local rec out status
  rec=$(make_pool_case getfail 1)
  read_pool_record "$rec"

  out=$(FM_FAKE_TREEHOUSE_GET_FAIL_AFTER_LEASE=1 run_pool_spawn lease-getfail-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although its lease get failed"$'\n'"$out"
  assert_contains "$out" "could not lease a Treehouse pool slot" \
    "the spawn did not refuse when its lease get failed"
  [ ! -e "$HOME_DIR/state/lease-getfail-r1.meta" ] \
    || fail "the failed get published a task record"
  [ ! -s "$POOL_DIR/.fake-leases" ] \
    || fail "a failed get stranded the lease it had recorded: $(cat "$POOL_DIR/.fake-leases")"
  grep -Fq "return --force $POOL_DIR/1/project" "$POOL_DIR/.fake-calls" \
    || fail "the abort path did not return the slot the failed get had leased: $(tail -3 "$POOL_DIR/.fake-calls")"
  pass "a failing get that recorded its lease returns it through the abort path"
}

# And a failed get that printed nothing leaves no path for the trap to return,
# so the abort path must warn that a lease may have been recorded instead of
# passing silently.
test_a_failing_silent_get_warns_that_the_lease_may_be_held() {
  local rec out status
  rec=$(make_pool_case getfailquiet 1)
  read_pool_record "$rec"

  out=$(FM_FAKE_TREEHOUSE_GET_FAIL_SILENT=1 run_pool_spawn lease-getquiet-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although its lease get failed"$'\n'"$out"
  assert_contains "$out" "may have recorded a lease before it failed" \
    "the aborted spawn did not warn that its lease may still be held"
  assert_contains "$out" "treehouse return --force --if-lease-holder lease-getquiet-r1" \
    "the warning did not name how to release a lease the failed get may have left"
  grep -Fxq "1 lease-getquiet-r1" "$POOL_DIR/.fake-leases" \
    || fail "the failed get's lease vanished without a return: $(cat "$POOL_DIR/.fake-leases")"
  pass "a failing silent get leaves its lease with a may-still-be-held warning"
}

# Under a treehouse-3.x-shaped fake, every return the abort trap and teardown
# issue is still a --force return, which is exactly the form 3.x needs to clean
# and return instead of refusing with exit 3 - so leases still free and slots
# still reuse with no caller change.
test_v3_shaped_treehouse_still_frees_leases_through_force_returns() {
  local rec out status
  rec=$(make_pool_case v3force 1 2)
  read_pool_record "$rec"

  # The model itself first: a plain return of a dirty checkout refuses with
  # exit 3 and the vendor's wording, leaving the checkout and lease untouched.
  printf 'uncommitted\n' > "$POOL_DIR/1/project/leftover.txt"
  out=$(FM_FAKE_TREEHOUSE_POOL="$POOL_DIR" FM_FAKE_TREEHOUSE_V3=1 \
    "$FAKEBIN_DIR/treehouse" return "$POOL_DIR/1/project" 2>&1)
  [ $? -eq 3 ] \
    || fail "the v3-shaped fake did not model the 3.x dirty refusal: $out"
  assert_contains "$out" "worktree not returned: it has uncommitted changes" \
    "the v3-shaped fake refused without the vendor's dirty wording"
  rm "$POOL_DIR/1/project/leftover.txt"

  # The abort-path rollback: a get that leases then fails is returned through
  # the trap's `treehouse return --force`, which a 3.x treehouse accepts.
  out=$(FM_FAKE_TREEHOUSE_V3=1 FM_FAKE_TREEHOUSE_GET_FAIL_AFTER_LEASE=1 \
    run_pool_spawn lease-v3-getfail-r1 "$POOL_DIR/1/project" --scout)
  [ $? -ne 0 ] || fail "spawn launched although its lease get failed"
  [ ! -s "$POOL_DIR/.fake-leases" ] \
    || fail "the v3-shaped rollback stranded a lease: $(cat "$POOL_DIR/.fake-leases")"
  grep -Fq "return --force $POOL_DIR/1/project" "$POOL_DIR/.fake-calls" \
    || fail "the v3-shaped abort path did not return through --force: $(tail -3 "$POOL_DIR/.fake-calls")"

  # Teardown of a clean task: the leased copy goes back through
  # `return --force --if-lease-holder` and the next spawn reuses the slot.
  out=$(FM_FAKE_TREEHOUSE_V3=1 run_pool_spawn lease-v3-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "the v3-shaped pool spawn should launch"$'\n'"$out"
  grep -Fxq "1 lease-v3-r1" "$POOL_DIR/.fake-leases" \
    || fail "the v3-shaped spawn did not lease its slot: $(cat "$POOL_DIR/.fake-leases")"
  printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/lease-v3-r1/report.md"
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete lease-v3-r1 --none >/dev/null

  out=$(FM_FAKE_TREEHOUSE_V3=1 run_pool_teardown lease-v3-r1)
  status=$?
  expect_code 0 "$status" "v3-shaped teardown of a clean scout should succeed"$'\n'"$out"
  grep -q "^1 " "$POOL_DIR/.fake-leases" \
    && fail "the v3-shaped teardown left the task's slot leased: $(cat "$POOL_DIR/.fake-leases")"
  grep -Fq "return --force --if-lease-holder lease-v3-r1 $POOL_DIR/1/project" \
    "$POOL_DIR/.fake-calls" \
    || fail "the v3-shaped teardown did not return through --force --if-lease-holder: $(tail -3 "$POOL_DIR/.fake-calls")"

  out=$(run_pool_spawn lease-v3-reuse-r1 "$POOL_DIR/1/project" --scout)
  status=$?
  expect_code 0 "$status" "a spawn after a v3-shaped teardown should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR/1/project" "$HOME_DIR/state/lease-v3-reuse-r1.meta" \
    "the next spawn was not handed the copy the v3-shaped teardown freed"
  pass "a treehouse-3.x-shaped dirty refusal never reaches firstmate's --force returns"
}

test_leased_slot_is_not_reissued_while_task_exists
test_teardown_frees_the_lease_for_reuse
test_a_failing_get_that_recorded_its_lease_returns_it
test_a_failing_silent_get_warns_that_the_lease_may_be_held
test_teardown_completes_for_a_record_with_no_lease
test_teardown_frees_the_lease_when_the_slot_directory_is_gone
test_teardown_leaves_an_absent_copy_leased_to_another_task
test_teardown_warns_when_an_absent_copys_path_is_no_longer_listed
test_teardown_refuses_a_slot_leased_to_another_task
test_child_cleanup_frees_the_lease_when_the_slot_directory_is_gone
test_child_cleanup_leaves_an_absent_copy_leased_to_another_task
test_child_cleanup_refuses_a_present_copy_leased_to_another_task
test_child_cleanup_refuses_a_preclaim_present_copy_leased_to_another_task
test_aborted_spawn_keeps_a_dirty_copys_work
test_failed_send_returns_its_lease
test_settle_timeout_returns_its_lease
test_v3_shaped_treehouse_still_frees_leases_through_force_returns

echo "# all fm-spawn-slot-lease tests passed"
