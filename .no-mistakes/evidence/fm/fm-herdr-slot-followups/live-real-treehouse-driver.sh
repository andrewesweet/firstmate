#!/usr/bin/env bash
# Ad-hoc live driver: exercises this change's fm-spawn/fm-teardown paths
# against the REAL treehouse binary in throwaway pools (max_trees=1).
set -u
cd "$1"
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot fm-live-followups)
TV=$(treehouse --version | head -1)
echo "# treehouse $TV"
holder_of() { jq -r --arg p "$1" '[(.worktrees//[])[]|select(.path==$p and (.leased//false))][0].lease_holder // ""' "$(dirname "$(dirname "$1")")/treehouse-state.json"; }
setup() { # <name>
  CASE="$TMP_ROOT/$1"; H="$CASE/home"; P="$CASE/project"; POOL="$CASE/pool"
  mkdir -p "$H/data" "$H/projects" "$H/state" "$H/config" "$POOL"
  printf 'codex\n' > "$H/config/crew-harness"; touch "$H/state/.last-watcher-beat"
  fm_git_init_commit "$P"
  printf 'max_trees = 1\nroot = "%s"\n' "$POOL" > "$P/treehouse.toml"
  git -C "$P" add treehouse.toml; git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm pin
  FB=$(make_spawn_fakebin "$CASE/fake"); fm_test_fake_sleep_noop "$FB"
}
rt() { ( cd "$P" && treehouse "$@" ); }
inpool() { case "$1" in "$POOL"/*) ;; *) echo "ABORT: slot $1 outside pool"; rt return --force "$1"; exit 2;; esac; }
teardown_run() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" PATH="$FB:$PATH" "$ROOT/bin/fm-teardown.sh" "$@" 2>&1; }
spawn_adopt() { # <id> <slot>  spawn with fake allocation adopting a real-leased slot
  fm_test_spawn_brief "$H" "$1"; fm_test_run_spawn "$H" "$2" "$FB" "$1" "$P" --scout >/dev/null || { echo "spawn failed"; exit 2; }
  rm -f "$FB/treehouse"
  printf '# Scout findings\n\nNo changes needed.\n' > "$H/data/$1/report.md"
  FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/fm-captain-hold.sh" complete "$1" --none >/dev/null
}

echo; echo "=== A: spawn against an exhausted REAL pool ==="
setup exhausted
S=$(rt get --lease --lease-holder other-task-r9 2>/dev/null); inpool "$S"
echo "pool slot $S leased to: $(holder_of "$S")"
rm -f "$FB/treehouse"   # spawn's own get --lease goes to the real binary
fm_test_spawn_brief "$H" live-exh-r1
out=$(fm_test_run_spawn "$H" "$S" "$FB" live-exh-r1 "$P" --scout); rc=$?
echo "fm-spawn exit=$rc"; echo "$out" | grep -E 'error:|warning:'
echo "record published? $([ -e "$H/state/live-exh-r1.meta" ] && echo yes || echo no)"
echo "slot holder after: $(holder_of "$S")"
echo "$out" | grep -q 'leased a Treehouse pool slot' && echo "RESULT A: FAIL (unhedged leased-slot claim)" || { echo "$out" | grep -q 'may have recorded a lease before it failed' && [ $rc -ne 0 ] && echo "RESULT A: PASS"; }

echo; echo "=== B: pre-claim record, REAL slot now leased to another task ==="
setup preclaim-other
S=$(rt get --lease --lease-holder live-pre-r1 2>/dev/null); inpool "$S"
spawn_adopt live-pre-r1 "$S"
rm -f "$(dirname "$S")/.fm-slot-owner"
rt return --force "$S" >/dev/null 2>&1
S2=$(rt get --lease --lease-holder other-live-r2 2>/dev/null); [ "$S2" = "$S" ] || { echo "reissued different slot $S2"; exit 2; }
printf 'other work\n' > "$S/other-task-work.txt"; git -C "$S" checkout -q -b other-task-branch
mkdir -p "$S/.claude" "$S/.opencode/plugins"; echo h > "$S/.claude/settings.local.json"; echo h > "$S/.opencode/plugins/fm-turn-end.js"; echo h > "$S/.fm-grok-turnend"
echo "slot holder before teardown: $(holder_of "$S")"
out=$(teardown_run live-pre-r1); rc=$?
echo "fm-teardown exit=$rc"; echo "$out" | grep -E 'error|warning' | head -5
ok=1
[ $rc -ne 0 ] || ok=0
for f in other-task-work.txt .claude/settings.local.json .opencode/plugins/fm-turn-end.js .fm-grok-turnend; do [ -f "$S/$f" ] && echo "kept $f" || { echo "LOST $f"; ok=0; }; done
echo "HEAD: $(git -C "$S" rev-parse --abbrev-ref HEAD)"; [ "$(git -C "$S" rev-parse --abbrev-ref HEAD)" = other-task-branch ] || ok=0
echo "slot holder after: $(holder_of "$S")"; [ "$(holder_of "$S")" = other-live-r2 ] || ok=0
echo "record kept? $([ -e "$H/state/live-pre-r1.meta" ] && echo yes || { ok=0; echo no; })"
[ $ok = 1 ] && echo "RESULT B: PASS" || echo "RESULT B: FAIL"
rt return --force --if-lease-holder other-live-r2 "$S" >/dev/null 2>&1

echo; echo "=== C: pre-claim record, REAL slot still leased to its own task ==="
setup preclaim-own
S=$(rt get --lease --lease-holder live-own-r1 2>/dev/null); inpool "$S"
spawn_adopt live-own-r1 "$S"
rm -f "$(dirname "$S")/.fm-slot-owner"
git -C "$S" checkout -q -b fm/live-own-r1
mkdir -p "$S/.claude"; echo h > "$S/.claude/settings.local.json"; echo h > "$S/.fm-kimi-turnend"
echo "slot holder before teardown: $(holder_of "$S")"
out=$(teardown_run live-own-r1); rc=$?
echo "fm-teardown exit=$rc"; echo "$out" | tail -4
ok=1; [ $rc -eq 0 ] || ok=0
echo "slot holder after: '$(holder_of "$S")'"; [ -z "$(holder_of "$S")" ] || ok=0
echo "record removed? $([ ! -e "$H/state/live-own-r1.meta" ] && echo yes || { ok=0; echo no; })"
for f in .claude/settings.local.json .fm-kimi-turnend; do [ -e "$S/$f" ] && { echo "hook left: $f"; ok=0; } || echo "hook swept: $f"; done
echo "HEAD: $(git -C "$S" rev-parse --abbrev-ref HEAD)"
git -C "$P" rev-parse --verify -q refs/heads/fm/live-own-r1 >/dev/null && { echo "branch ref fm/live-own-r1 still present"; ok=0; } || echo "branch ref fm/live-own-r1 dropped"
S3=$(rt get --lease --lease-holder reuse-r1 2>/dev/null); echo "re-lease after teardown -> $S3"; [ "$S3" = "$S" ] || ok=0
rt return --force "$S" >/dev/null 2>&1
[ $ok = 1 ] && echo "RESULT C: PASS" || echo "RESULT C: FAIL"
