#!/usr/bin/env bash
# Live adversarial scenario for the durable task-slot lease.
#
# Intent under test: a task's pooled worktree stays reserved for that task for
# as long as the task exists, EVEN WHEN EVERY AGENT PROCESS LEAVES IT - the
# Herdr-restart shape where treehouse's cwd heuristic would judge the slot free.
#
# Driven against the REAL treehouse on PATH and the REAL bin/fm-spawn.sh /
# bin/fm-teardown.sh, in a throwaway pool pinned by a committed treehouse.toml.
set -u
. "$1/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-lease-reissue-live)
TREEHOUSE_VERSION=$(treehouse --version 2>/dev/null | head -1)

CASE="$TMP_ROOT/case"
HOME_DIR="$CASE/home"
PROJECT_DIR="$CASE/project"
POOL_DIR="$CASE/pool"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$POOL_DIR"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"
fm_git_init_commit "$PROJECT_DIR"
printf 'root = "%s"\n' "$POOL_DIR" > "$PROJECT_DIR/treehouse.toml"
git -C "$PROJECT_DIR" add treehouse.toml
git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm 'pin the guard pool'

real_treehouse() { ( cd "$PROJECT_DIR" && treehouse "$@" ); }
state_file() { printf '%s/treehouse-state.json\n' "$(dirname "$(dirname "$1")")"; }
holder_of() {
  jq -r --arg p "$1" \
    '[(.worktrees // [])[] | select(.path == $p and (.leased // false))][0].lease_holder // ""' \
    "$(state_file "$1")"
}
in_pool() { case "$1" in "$POOL_DIR"/*) ;; *) fail "treehouse leased '$1' outside $POOL_DIR" ;; esac; }

A=reissue-live-a
B=reissue-live-b

# --- task A: a real spawn takes and records a real leased pool slot ----------
SLOT_A=$(real_treehouse get --lease --lease-holder "$A") || fail "could not lease slot A"
in_pool "$SLOT_A"
FAKEBIN=$(make_spawn_fakebin "$CASE/fake")
fm_test_fake_sleep_noop "$FAKEBIN"
fm_test_spawn_brief "$HOME_DIR" "$A"
out=$(fm_test_run_spawn "$HOME_DIR" "$SLOT_A" "$FAKEBIN" "$A" "$PROJECT_DIR" --scout) \
  || fail "spawn A failed"$'\n'"$out"
assert_grep "worktree=$SLOT_A" "$HOME_DIR/state/$A.meta" "spawn A did not record its leased slot"
[ "$(holder_of "$SLOT_A")" = "$A" ] || fail "treehouse does not record $SLOT_A leased to $A"
echo "ok - task $A holds a real treehouse lease on $SLOT_A"

# --- the Herdr-restart shape: NOTHING has its cwd inside task A's slot ------
# (no agent process was ever started here; assert it rather than assume it)
if command -v lsof >/dev/null 2>&1; then
  lsof +D "$SLOT_A" >/dev/null 2>&1 && fail "a process still holds $SLOT_A open"
fi
for p in /proc/[0-9]*; do
  cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
  case "$cwd" in "$SLOT_A"|"$SLOT_A"/*) fail "pid ${p#/proc/} still has its cwd in $SLOT_A" ;; esac
done
echo "ok - no process on this host has its cwd inside $SLOT_A (treehouse's free-slot heuristic would call it free)"

# --- adversarial: a later spawn must NOT be handed task A's live slot -------
rm -f "$FAKEBIN/treehouse"   # the REAL binary allocates for task B
PROBE=$( ( cd "$PROJECT_DIR" && treehouse get --lease --lease-holder reissue-live-probe ) ) \
  || fail "the real treehouse refused a second lease"
in_pool "$PROBE"
[ "$PROBE" != "$SLOT_A" ] || fail "treehouse $TREEHOUSE_VERSION REISSUED task $A's leased slot $SLOT_A"
real_treehouse return --force --if-lease-holder reissue-live-probe "$PROBE" >/dev/null

fm_test_spawn_brief "$HOME_DIR" "$B"
out=$(fm_test_run_spawn "$HOME_DIR" "$PROBE" "$FAKEBIN" "$B" "$PROJECT_DIR" --scout) \
  || fail "spawn B failed"$'\n'"$out"
SLOT_B=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$B.meta")
[ "$SLOT_B" != "$SLOT_A" ] || fail "the real spawn of task $B was handed task $A's slot $SLOT_A"
[ "$(holder_of "$SLOT_A")" = "$A" ] || fail "task $A lost its lease to the second spawn"
[ "$(holder_of "$SLOT_B")" = "$B" ] || fail "task $B's slot $SLOT_B is not leased to $B"
echo "ok - a second real spawn got $SLOT_B, not task $A's slot; $A keeps its lease with no process inside it"

# --- teardown frees A's slot and the pool reissues it ------------------------
printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/$A/report.md"
FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-captain-hold.sh" complete "$A" --none >/dev/null
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-teardown.sh" "$A" 2>&1) || fail "teardown of $A failed"$'\n'"$out"
[ -z "$(holder_of "$SLOT_A")" ] || fail "teardown left $SLOT_A leased to '$(holder_of "$SLOT_A")'"$'\n'"$out"
REUSE=$(real_treehouse get --lease --lease-holder reissue-live-c) || fail "no slot after teardown"
[ "$REUSE" = "$SLOT_A" ] || fail "teardown freed the lease but the pool handed $REUSE, not $SLOT_A"
real_treehouse return --force --if-lease-holder reissue-live-c "$REUSE" >/dev/null
echo "ok - teardown of $A released its lease and the pool reissued $SLOT_A to the next taker"

# --- adversarial: teardown must refuse a slot leased to another task ---------
# Point task B's record at task A's (now free, then re-leased elsewhere) slot.
OTHER=$(real_treehouse get --lease --lease-holder some-other-task) || fail "could not lease the foreign slot"
sed -i "s|^worktree=.*|worktree=$OTHER|" "$HOME_DIR/state/$B.meta"
printf '# Scout findings\n\nNo changes needed.\n' > "$HOME_DIR/data/$B/report.md"
FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-captain-hold.sh" complete "$B" --none >/dev/null
set +e
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-teardown.sh" "$B" 2>&1)
st=$?
set -e
[ "$st" -ne 0 ] || fail "teardown of $B took a slot leased to some-other-task"$'\n'"$out"
[ "$(holder_of "$OTHER")" = some-other-task ] || \
  fail "teardown of $B released another task's lease on $OTHER"
[ -e "$HOME_DIR/state/$B.meta" ] || fail "teardown dropped the record after refusing"
printf 'refusal: %s\n' "$(printf '%s' "$out" | grep -i 'lease\|refus' | head -3)"
echo "ok - teardown refused a slot leased to another task, leaving that lease and the record intact"

real_treehouse return --force --if-lease-holder some-other-task "$OTHER" >/dev/null
echo "# all live reissue scenarios passed (treehouse $TREEHOUSE_VERSION)"
