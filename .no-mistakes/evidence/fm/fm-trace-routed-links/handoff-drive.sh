#!/usr/bin/env bash
set -u
ROOTDIR=/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M2D66917EDY6ECXGXA0YCQKB
. "$ROOTDIR/tests/secondmate-helpers.sh"
TMP_ROOT=$(fm_test_tmproot nm-live-handoff)
CARRIER='00-99999999999999999999999999999999-8888888888888888-01'
setup() { # <home> <sub> <on|off>
  local home=$1 sub=$2 id=design
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$sub" "$id"
  local sub_abs; sub_abs=$(cd "$sub" && pwd -P)
  printf -- '- %s - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' "$id" "$sub_abs" > "$home/data/secondmates.md"
  printf 'window=firstmate:fm-%s\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\nworktree=%s\ntraceparent=%s\n' "$id" "$sub_abs" "$sub_abs" "$CARRIER" > "$home/state/$id.meta"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s %s\n' "$$" "$3" > "$home/state/.trace-context-effective"
  printf '## Queued\n- [ ] live-a - first routed item (repo: alpha)\n- [ ] live-b - second routed item (repo: alpha)\n\n## Done\n' > "$home/data/backlog.md"
  printf '## Queued\n\n## Done\n' > "$sub/data/backlog.md"
}
run() { # <home> <keys...>
  local home=$1; shift
  local fakebin; fakebin=$(make_fake_tmux "$TMP_ROOT/fake-$RANDOM")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOTDIR" PATH="$fakebin:$PATH" \
    FM_FAKE_TMUX_WINDOW='firstmate:fm-design' FM_FAKE_TMUX_LOG="$TMP_ROOT/tmux.log" FM_FAKE_TMUX_CAPTURE="$fakebin/../pane.txt" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:47318 \
    "$ROOTDIR/bin/fm-backlog-handoff.sh" design "$@"
}
echo "### which curl: $(command -v curl)"
echo "### [on] handoff design live-a live-b"
setup "$TMP_ROOT/on-main" "$TMP_ROOT/on-sub" on
run "$TMP_ROOT/on-main" live-a live-b; echo "rc=$?"
echo "### secondmate backlog after handoff:"; cat "$TMP_ROOT/on-sub/data/backlog.md"
echo "### [off] handoff design live-a live-b (tracing effective off)"
setup "$TMP_ROOT/off-main" "$TMP_ROOT/off-sub" off
run "$TMP_ROOT/off-main" live-a live-b; echo "rc=$?"
