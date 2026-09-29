#!/usr/bin/env bash
# Live: an aborted spawn strands no treehouse lease.
# The REAL treehouse allocates; the pane is forced to stay in the project, so
# the isolation settle poll refuses the launch. The pool state must show the
# slot free afterwards, and the pool must reissue it.
set -u
. "$1/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-lease-abort-live)
CASE="$TMP_ROOT/case"; HOME_DIR="$CASE/home"; PROJECT_DIR="$CASE/project"; POOL_DIR="$CASE/pool"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$POOL_DIR"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"; touch "$HOME_DIR/state/.last-watcher-beat"
fm_git_init_commit "$PROJECT_DIR"
printf 'root = "%s"\n' "$POOL_DIR" > "$PROJECT_DIR/treehouse.toml"
git -C "$PROJECT_DIR" add treehouse.toml
git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm 'pin the guard pool'
real_treehouse() { ( cd "$PROJECT_DIR" && treehouse "$@" ); }
holders() {
  jq -r '[(.worktrees // [])[] | select(.leased // false) | .lease_holder] | join(",")' \
    "$POOL_DIR/.treehouse"/*/treehouse-state.json
}

ID=abort-live-a
FAKEBIN=$(make_spawn_fakebin "$CASE/fake"); rm -f "$FAKEBIN/treehouse"
fm_test_fake_sleep_noop "$FAKEBIN"
fm_test_spawn_brief "$HOME_DIR" "$ID"
set +e
out=$(fm_test_run_spawn "$HOME_DIR" "$PROJECT_DIR" "$FAKEBIN" "$ID" "$PROJECT_DIR" --scout)
st=$?
set -e
[ "$st" -ne 0 ] || fail "the spawn should have refused: its endpoint never entered the leased copy"$'\n'"$out"
printf 'spawn refusal: %s\n' "$(printf '%s' "$out" | grep -i 'isolated worktree\|lease' | head -3)"
[ -z "$(holders)" ] || fail "the aborted spawn stranded a treehouse lease held by '$(holders)'"$'\n'"$out"
[ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "the aborted spawn left a task record"
SLOT=$(real_treehouse get --lease --lease-holder abort-live-next) || fail "the pool would not issue a slot"
real_treehouse return --force --if-lease-holder abort-live-next "$SLOT" >/dev/null
echo "ok - an aborted spawn returned its real lease; the pool reissued $SLOT to the next taker"
