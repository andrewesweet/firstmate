#!/usr/bin/env bash
# tests/fm-watch-triage-wedges.test.sh - the escalation half of the always-on
# wake triage built into bin/fm-watch.sh: when a stale or paused lane climbs
# the wedge ladder and when it defers. Split from fm-watch-triage.test.sh so
# the portable serial shard carrying it stays under its CI job cap; that file
# keeps the classifier predicates, absorb/no-verb and stale-core surfaces, the
# heartbeat backstop, and afk coherence, and drives the same real watcher
# subprocess. Shared case drivers live in watch-triage-helpers.sh.
#
# Covered here: wedge-threshold deferrals (backlog captain holds, a worker's
# own blocker behind its opt-in flag, executing validation runs, off-until-
# armed knobs), wedge guards (absent config, critical-window deferral, guard
# failures failing open, gone endpoints never deferred), bounded unknown-alive
# staleness, paused workers rechecked on declared waits and background-job
# ends, recovery rearm/ack semantics across restarts, and exit-picker
# staleness naming the blocking dialog.

set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-wedges-tests)

# A Codex pane can be recovery-grade alive while its busy state remains
# unverified. Its first stale sight must still wake for inspection. A new render
# after that handled wake is bounded only while the pane shows progress evidence
# (its own status log or task worktree written within FM_STALE_ESCALATE_SECS);
# without it every new hash keeps surfacing, so an animated wedge stays loud.
unknown_alive_stale_case() {  # <evidence: status|worktree|none>
  local evidence=$1 dir state fakebin out capture_file window key previous wakes pid old
  dir=$(make_case "unknown-alive-stale-$evidence"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-codexunknown"
  old=$(( $(date +%s) - 1000 ))
  printf 'unreadable long Codex turn\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=codex\nbackend=tmux\n' "$window" > "$state/codexunknown.meta"
  printf 'working: recovering source files\n' > "$state/codexunknown.status"
  if [ "$evidence" != status ]; then
    set_mtime "$old" "$state/codexunknown.status"
    mkdir -p "$dir/wt/src"
    printf 'worktree=%s\n' "$dir/wt" >> "$state/codexunknown.meta"
    : > "$dir/wt/src/old.c"; set_mtime "$old" "$dir/wt/src/old.c"
    [ "$evidence" != worktree ] || printf 'recovered\n' > "$dir/wt/src/recovered.c"
  fi
  printf '%s' "$(seen_sig "$state/codexunknown.status")" > "$state/.seen-codexunknown_status"
  key=$(printf '%s' "$window" | tr ':/. ' '____')
  printf '%s' "$(hash_text 'unreadable long Codex turn')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown codex-unverified)'
  export FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_FAKE_TMUX_CURRENT_COMMAND=codex
  export FM_PAUSE_RESURFACE_SECS=999

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "[$evidence] the first unknown-but-alive stale sight did not surface"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "[$evidence] the first unknown-but-alive alarm changed its wording"
  if [ "$evidence" = none ]; then
    [ ! -e "$state/.paused-resurfaced-$key" ] || fail "[none] an alarm without progress evidence recorded a repeat bound"
  else
    [ -s "$state/.paused-resurfaced-$key" ] || fail "[$evidence] the first alarm with progress evidence did not record its bound"
  fi
  ack_stopped_cycle "$state" || fail "[$evidence] could not acknowledge the first unknown-but-alive alarm"

  # A successor sees a different rendered hash, exactly as a long Codex turn
  # updates its viewport, but the same known-live, unclassifiable endpoint.
  printf 'unreadable long Codex turn, later viewport\n' > "$capture_file"
  previous=$(hash_text 'earlier unreadable Codex turn')
  printf '%s' "$previous" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if [ "$evidence" = none ]; then
    wait_for_exit "$pid" 100 || fail "[none] an unknown-but-alive pane without progress evidence went quiet"
    grep -Fx "stale: $window" "$out" >/dev/null \
      || fail "[none] an unknown-but-alive pane without progress evidence did not re-surface: $(cat "$out")"
    unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_WINDOW FM_FAKE_TMUX_CURRENT_COMMAND FM_FAKE_TMUX_CAPTURE FM_PAUSE_RESURFACE_SECS
    return 0
  fi
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "[$evidence] a bounded unknown-but-alive successor exited"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "[$evidence] could not acknowledge the bounded unknown-but-alive successor stop"
  [ ! -s "$out" ] || fail "[$evidence] a bounded unknown-but-alive successor printed a stale wake: $(cat "$out")"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "[$evidence] a bounded unknown-but-alive successor queued $wakes repeat wakes"

  # Expiring the bound restores the original first-sight alarm without changing
  # its wake type or wording.
  set_mtime "$(( $(date +%s) - 1000 ))" "$state/.paused-resurfaced-$key"
  printf 'unreadable long Codex turn, another later viewport\n' > "$capture_file"
  previous=$(hash_text 'yet another unreadable Codex turn')
  printf '%s' "$previous" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "[$evidence] an expired unknown-but-alive bound did not re-surface"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "[$evidence] the expired unknown-but-alive bound changed wake wording: $(cat "$out")"
  unset FM_FAKE_CREW_STATE FM_FAKE_TMUX_WINDOW FM_FAKE_TMUX_CAPTURE FM_FAKE_TMUX_CURRENT_COMMAND FM_PAUSE_RESURFACE_SECS
}

# The backlog record of the same hold. Once firstmate hands a decision to the
# captain through bin/fm-captain-hold.sh, the worker's own line stays whatever it
# was, so a stuck worker on a stable pane reaches the wedge timer with nothing in
# its status log that reads as a wait. The open captain call must bound the wedge
# ladder exactly as a `captain-held:` line does.
backlog_hold_wedge_fixture() {  # <name> <status-age-secs> [<wedge-timer-age-secs>] [<status-log>]
  local dir
  dir=$(wedge_threshold_fixture "$1" "${4:-working: answering the dialog}" "$2" "${3-}") || return 1
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml" || return 1
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add wedge 'stuck at a captain-only dialog' --file data/backlog.md) >/dev/null 2>&1 \
    || return 1
  run_hold "$dir" hold wedge --reason 'awaiting the captain on the dialog' || return 1
  printf '%s\n' "$dir"
}

# --- a worker's own newest blocker or decision, behind its opt-in flag -------
# Upstream kunchenguid/firstmate#6899: a lane whose newest line is the worker's
# own `blocked:` or `needs-decision:` already woke firstmate, so in a home that
# armed config/wedge-defer-worker-wait the wedge timer defers it to the bounded
# recheck instead of climbing the ladder. `blocked:` is the verb pinned here
# because the parked-gate evidence above deliberately refuses it. A `blocked:`
# last line is captain-relevant, so every fixture arms the wedge timer (the
# fourth argument) to reach it through the overridden-terminal-status branch.
arm_worker_wait() {  # <case-dir>
  : > "$1/config/wedge-defer-worker-wait"
}

# --- an executing no-mistakes run is liveness, not a wedge candidate ---------
# While the pipeline runs or fixes a round the worker is idle behind its own
# blocking drive call, so a static pane is exactly what a healthy lane looks
# like. The attributed run step says so, and in a home that armed
# config/wedge-defer-validating the wedge timer defers to it on the same long
# recheck cadence as every other deferral instead of re-escalating a possible
# wedge each FM_STALE_ESCALATE_SECS.
arm_validating() {  # <case-dir>
  : > "$1/config/wedge-defer-validating"
}

# Write one guard executable into the case. Every call appends the task,
# endpoint and argv it received to <case-dir>/guard.calls before <body> runs.
make_wedge_guard() {  # <case-dir> <name> <body> -> guard path
  local dir=$1 name=$2 body=$3 f
  mkdir -p "$dir/guards"
  f="$dir/guards/$name"
  # shellcheck disable=SC2016 # single quotes are deliberate: the guard's own variables expand when the guard runs, not here
  printf '#!/bin/sh\nprintf "%%s %%s %%s\\n" "$FM_GUARD_TASK" "$FM_GUARD_ENDPOINT" "$*" >> "%s/guard.calls"\n%s\n' \
    "$dir" "$body" > "$f"
  chmod 700 "$f"
  printf '%s\n' "$f"
}

arm_wedge_guards() {  # <case-dir> <guard-path>...
  local dir=$1
  shift
  printf '%s\n' '# operator guards' '' "$@" > "$dir/config/wedge-evidence-guards"
  chmod 600 "$dir/config/wedge-evidence-guards"
}

wedge_guard_calls() {  # <case-dir>
  if [ -e "$1/guard.calls" ]; then wc -l < "$1/guard.calls" | tr -d ' '; else echo 0; fi
}

# --- a live worker paused on its own background job --------------------------
# A worker declared `paused:` on its own background job and the job then ended
# without a new status line, so only the passage of time can tell the watcher
# the wait should be over. Without `until`, the first-sight alert spends the
# declaration's re-surface throttle and every later sight - including the one
# after the job ended - is held for PAUSE_RESURFACE_SECS. Naming the job's
# start plus its timeout as `until` gives that same declaration one recheck once
# the job can no longer be running.
bg_job_paused_case() {  # <name> <status-line> -> dir
  local dir state window key
  dir=$(make_case "$1"); state="$dir/state"; window="test:fm-parked"
  printf 'window=%s\nkind=scout\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
  printf '%s\n' "$2" > "$state/parked.status"
  printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'nightly build running' > "$dir/pane.txt"
  printf '%s' "$(hash_text 'nightly build running')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

bg_job_stale_wakes() {  # <state> -> count of stale wakes queued for the parked window
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-parked" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# The recorded Claude background-task exit picker. The footer is the last
# non-blank row, which is what fm_composer_blocking_dialog requires.
write_exit_picker() {  # <file>
  printf '%s\n' \
    'Background work is running' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '❯ 1. Exit and stop tasks' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel' > "$1"
}

# The same words quoted above a normal composer. That is not a live picker.
write_quoted_exit_picker() {  # <file>
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm · Esc to cancel' \
    '╭──────────────╮' \
    '│ > next steer │' \
    '╰──────────────╯' > "$1"
}

prime_picker_window() {  # <state> <id> <window> <kind> <capture> <status-line>
  local state=$1 id=$2 window=$3 kind=$4 capture=$5 status_line=$6 key statusf
  statusf="$state/$id.status"
  printf 'window=%s\nkind=%s\nbackend=tmux\n' "$window" "$kind" > "$state/$id.meta"
  printf '%s\n' "$status_line" > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$key"
}

test_unknown_alive_stale_is_bounded_after_its_first_alarm() {
  unknown_alive_stale_case status
  unknown_alive_stale_case worktree
  pass "an unknown-but-alive pane with progress evidence alarms once per bounded pause-resurface window"
}

test_unknown_alive_stale_without_progress_keeps_surfacing() {
  unknown_alive_stale_case none
  pass "an unknown-but-alive pane without progress evidence keeps surfacing every new hash"
}

WEDGE_GUARD_CRITICAL='printf "%s\n" "{\"name\":\"ticket\",\"status\":\"CRITICAL\",\"recommendation\":\"ticket 7 is held by a live job\"}"'

test_wedge_guards_absent_config_keeps_the_unchanged_ladder() {
  local dir state fakebin out capture window key n guard
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  dir=$(wedge_threshold_fixture guards-absent 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL" >/dev/null
  [ ! -e "$dir/config/wedge-evidence-guards" ] \
    || fail "the unconfigured fixture armed the guards, so it proves nothing"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an unconfigured home stopped escalating at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge unconfigured escalation $n"
    [ "$n" -ge 3 ] \
      || grep -E "^stale: $window \(idle [0-9]+s, possible wedge, escalation $n\)\$" "$out" >/dev/null \
      || fail "an unconfigured home changed escalation $n's reason: $(cat "$out")"
    n=$((n + 1))
  done
  grep -F 'escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone)' "$out" >/dev/null \
    || fail "an unconfigured home lost the demand-deep-inspection wording: $(cat "$out")"
  grep -F 'guard' "$out" >/dev/null && fail "an unconfigured home named a guard: $(cat "$out")"
  [ "$(wedge_guard_calls "$dir")" -eq 0 ] \
    || fail "an unconfigured home ran a guard $(wedge_guard_calls "$dir") time(s)"
  [ ! -e "$state/.guard-deferrals-$key" ] || fail "an unconfigured home wrote a guard-deferral record"

  # The same fixture with only the config added must reach the guard.
  dir=$(wedge_threshold_fixture guards-armed-control 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
  arm_wedge_guards "$dir" "$guard"
  FM_WEDGE_GUARD_DEFER_MAX=0 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "the armed control did not escalate with a zero deferral cap: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the armed control"
  [ "$(wedge_guard_calls "$dir")" -gt 0 ] \
    || fail "the armed control ran no guard, so the zero above proves nothing"
  pass "with config/wedge-evidence-guards absent no guard runs and the ladder, timing and wording are unchanged"
}

test_wedge_guard_critical_defers_one_window_at_a_time_up_to_the_cap() {
  local dir state fakebin out capture window key guard
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture guards-critical 'working: running the remote suite' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
  arm_wedge_guards "$dir" "$guard"
  export FM_WEDGE_GUARD_DEFER_MAX=2

  # Two thresholds are deferred, one window each, and the third escalates
  # anyway: the guard is asked once per window, never twice in one.
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a CRITICAL guard silenced the lane past its deferral cap: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the capped escalation"
  [ "$(wedge_guard_calls "$dir")" -eq 3 ] \
    || fail "a cap of 2 asked the guard $(wedge_guard_calls "$dir") time(s) before escalating, not 3: $(cat "$dir/guard.calls")"
  grep -Fx "wedge $window --json" "$dir/guard.calls" >/dev/null \
    || fail "the guard did not receive the task, endpoint and --json: $(cat "$dir/guard.calls")"
  grep -F "possible wedge, escalation 1; guard ticket still reports CRITICAL (ticket 7 is held by a live job) after its consecutive-deferral cap, so recheck the lane)" "$out" >/dev/null \
    || fail "the capped escalation did not name the guard and its reason: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null)" = 1 ] \
    || fail "guard deferrals advanced the escalation count"
  [ ! -e "$state/.guard-deferrals-$key" ] || fail "the escalation did not end the deferral run"

  # The escalation ended the run, so a guard that stays CRITICAL still lets the
  # lane escalate once every cap+1 windows, with the count climbing as before.
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a CRITICAL guard silenced the lane after its first capped escalation: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the second capped escalation"
  grep -F "possible wedge, escalation 2; guard ticket still reports CRITICAL" "$out" >/dev/null \
    || fail "the second capped escalation did not keep counting: $(cat "$out")"

  # The run is a durable record, not memory: a restarted watcher resumes it.
  dir=$(wedge_threshold_fixture guards-restart 'working: running the remote suite' 0 5)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
  arm_wedge_guards "$dir" "$guard"
  printf '2\n' > "$state/.guard-deferrals-$key"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a restarted watcher forgot the deferral run: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the restarted escalation"
  [ "$(wedge_guard_calls "$dir")" -eq 1 ] \
    || fail "a restarted watcher deferred again past a recorded full run: $(cat "$dir/guard.calls")"
  unset FM_WEDGE_GUARD_DEFER_MAX
  pass "a CRITICAL guard defers one window at a time, the cap escalates naming the guard, and the run survives a restart"
}

test_wedge_guard_failures_fail_open() {
  local dir state fakebin out capture window key spec label body guard
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for spec in \
    'timeout|sleep 10' \
    'nonzero|printf "%s\n" "{\"status\":\"CRITICAL\",\"recommendation\":\"r\"}"; exit 3' \
    'malformed|printf "%s\n" "CRITICAL ticket 7"' \
    'two-documents|printf "%s\n" "{\"status\":\"CRITICAL\",\"recommendation\":\"r\"}" "{\"status\":\"OK\",\"recommendation\":\"r\"}"' \
    'empty-reason|printf "%s\n" "{\"status\":\"CRITICAL\",\"recommendation\":\" \"}"' \
    'unknown|printf "%s\n" "{\"status\":\"UNKNOWN\",\"recommendation\":\"cannot read the queue\"}"' \
    'warning|printf "%s\n" "{\"status\":\"WARNING\",\"recommendation\":\"queue is slow\"}"'; do
    label=${spec%%|*}; body=${spec#*|}
    dir=$(wedge_threshold_fixture "guards-fail-open-$label" 'working: still compiling' 0)
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    guard=$(make_wedge_guard "$dir" "$label" "$body")
    arm_wedge_guards "$dir" "$guard"
    FM_WEDGE_GUARD_TIMEOUT_SECS=1 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "a $label guard took the ladder away: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the $label escalation"
    grep -E "^stale: $window \(idle [0-9]+s, possible wedge, escalation 1\)$" "$out" >/dev/null \
      || fail "a $label guard changed the escalation: $(cat "$out")"
    [ "$(wedge_guard_calls "$dir")" -ge 1 ] || fail "the $label guard was never asked, so this proves nothing"
    [ ! -e "$state/.guard-deferrals-$key" ] || fail "a $label guard recorded a deferral"
  done

  # Untrusted configuration is never executed: a group-writable list, and a
  # listed guard writable by others, each keep the unchanged escalation.
  for label in config guard; do
    dir=$(wedge_threshold_fixture "guards-untrusted-$label" 'working: still compiling' 0)
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
    arm_wedge_guards "$dir" "$guard"
    case "$label" in
      config) chmod 660 "$dir/config/wedge-evidence-guards" ;;
      guard) chmod 777 "$guard" ;;
    esac
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an untrusted $label took the ladder away: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the untrusted-$label escalation"
    grep -F 'possible wedge, escalation 1)' "$out" >/dev/null \
      || fail "an untrusted $label changed the escalation: $(cat "$out")"
    [ "$(wedge_guard_calls "$dir")" -eq 0 ] || fail "an untrusted $label was executed"
  done
  pass "a guard that times out, fails, answers malformed, UNKNOWN or WARNING, or is untrusted leaves the ladder unchanged"
}

test_wedge_guard_never_defers_a_gone_endpoint() {
  local dir state fakebin out capture window guard
  local failed='state: failed · source: run-step · run failed'
  window="test:fm-wedge"
  dir=$(wedge_threshold_fixture guards-gone 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
  arm_wedge_guards "$dir" "$guard"
  gone_endpoint_env missing; export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "a CRITICAL guard hid a gone endpoint: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the gone report"
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  grep -F 'agent missing' "$out" >/dev/null || fail "the gone endpoint was not reported as gone: $(cat "$out")"
  [ "$(wedge_guard_calls "$dir")" -eq 0 ] || fail "a guard was asked about a gone endpoint"
  pass "a gone endpoint is reported before any guard is asked, so a guard never defers it"
}

test_wedge_threshold_defers_to_a_backlog_captain_hold() {
  local dir state fakebin out capture window key n queued armed_timer past
  local working='state: working · source: run-step · ci running'
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (backlog captain hold wedge bound)"; return 0; }
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  # A fresh status line is no record of when the hold began, so the first
  # threshold rechecks it once, as a wait on the captain with no wait age.
  dir=$(backlog_hold_wedge_fixture backlog-hold-quiet 0) \
    || fail "could not build a backlog captain-hold wedge fixture"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" \
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a backlog-held lane was never rechecked at the threshold: $(cat "$out")"
  grep -F 'awaiting the captain' "$out" >/dev/null \
    || fail "the backlog-hold recheck did not name the captain: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "a backlog-held lane was reported as a possible wedge: $(cat "$out")"
  grep -E ', waiting [0-9]+s' "$out" >/dev/null \
    && fail "the backlog-hold recheck published the status line's age as the hold's: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the backlog-hold recheck"

  # Inside the recheck cadence the hold is absorbed whole, threshold after threshold.
  queued=$(wedge_stale_wakes "$state" "$window")
  n=1
  while [ "$n" -le 3 ]; do
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" \
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a backlog-held lane wedge-escalated at threshold $n: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq "$queued" ] \
    || fail "a backlog-held lane queued a further wake inside its recheck cadence: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a backlog-held lane counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # A paused line whose own clearing time has passed explains nothing, so the
  # hold the worker's line never shows still bounds the ladder.
  past=$(iso_utc_at "$(( $(date +%s) - 7200 ))")
  dir=$(backlog_hold_wedge_fixture backlog-hold-elapsed-pause 0 '' \
    "paused: waiting on the build queue until $past") \
    || fail "could not build a backlog captain-hold wedge fixture"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" \
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a backlog-held lane behind an elapsed pause was never rechecked: $(cat "$out")"
  grep -F 'awaiting the captain' "$out" >/dev/null \
    || fail "a backlog-held lane behind an elapsed pause was not rechecked as a wait on the captain: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "a backlog-held lane behind an elapsed pause was reported as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a backlog-held lane behind an elapsed pause counted a wedge escalation"
  ack_stopped_cycle "$state" || fail "could not acknowledge the elapsed-pause backlog-hold recheck"

  # While the away-posture record exists it is never rechecked, and the backlog
  # read that proves the hold is paced by the idle timer rather than every poll.
  dir=$(backlog_hold_wedge_fixture backlog-hold-away 2000 2000) \
    || fail "could not build a backlog captain-hold wedge fixture"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  armed_timer=$(cat "$state/.stale-since-$key")
  write_away_record "$state"
  n=1
  while [ "$n" -le 3 ]; do
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_TEST_PAUSE_RESURFACE=240 \
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a backlog-held lane was rechecked at threshold $n while the away-posture record existed: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a backlog-held lane woke the away captain: $(cat "$state/.wake-queue")"
  [ ! -s "$out" ] \
    || fail "a backlog-held lane printed a recheck while the away-posture record existed: $(cat "$out")"
  [ "$(cat "$state/.stale-since-$key")" != "$armed_timer" ] \
    || fail "an away-silenced backlog hold left the idle timer expired, so its backlog read repeats on every poll"
  pass "a backlog captain hold bounds the wedge ladder like a captain-held line, and stays silent while the captain is away"
}

test_wedge_threshold_defers_to_a_worker_blocker() {
  local dir state fakebin out capture window key n reported case_log
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  dir=$(wedge_threshold_fixture worker-blocker-fresh \
    'working: wiring the client
blocked: need the API key for the staging account' 0 600)
  arm_worker_wait "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
      || fail "a worker blocker wedge-escalated at threshold $n in an armed home: $(cat "$out")"
    n=$((n + 1))
  done
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "a worker blocker queued a wake inside the recheck cadence: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a worker blocker counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # The deferral is bounded: once the blocker is older than the cadence it
  # re-surfaces once, aged from the line, naming firstmate and the clearing action.
  dir=$(wedge_threshold_fixture worker-blocker-aged 'blocked: need the API key for the staging account' 2000 600)
  arm_worker_wait "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a worker blocker older than the recheck cadence was never rechecked: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the worker-blocker recheck"
  reported=$(wedge_reported_wait_secs "$out")
  [ -n "$reported" ] && [ "$reported" -ge 1900 ] \
    || fail "the worker-blocker recheck reported '${reported}'s rather than the blocker's age: $(cat "$out")"
  grep -F 'declared blocker, awaiting firstmate' "$out" >/dev/null \
    || fail "the worker-blocker recheck did not name its evidence and firstmate: $(cat "$out")"
  grep -F 'clear the reported blocker' "$out" >/dev/null \
    || fail "the worker-blocker recheck lost its blocker-specific action: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "the worker-blocker recheck was worded as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the worker-blocker recheck raised the escalation count"

  dir=$(wedge_threshold_fixture worker-decision-aged 'needs-decision [key=scope]: ship the narrow fix or the broad one' 2000 600)
  arm_worker_wait "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a worker decision older than the recheck cadence was never rechecked: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the worker-decision recheck"
  grep -F 'declared decision, awaiting firstmate' "$out" >/dev/null \
    || fail "the worker-decision recheck did not name its evidence and firstmate: $(cat "$out")"
  grep -F 'answer the reported decision' "$out" >/dev/null \
    || fail "the worker-decision recheck lost its decision-specific action: $(cat "$out")"

  # Each of these ends or never starts the deferral, so the lane keeps the ladder:
  # a newer worker line, a resolved line, a supervisor-reserved key, and an inbox
  # record the worker acknowledged after writing the blocker.
  for case_log in \
    'blocked: need the API key for the staging account
working: resumed without it' \
    'blocked: need the API key for the staging account
resolved: firstmate supplied the key' \
    'blocked [key=remote-reply-continuity-mate1]: the remote reply mirror stopped' \
    'blocked: need the API key for the staging account|handled'; do
    dir=$(wedge_threshold_fixture worker-blocker-ended "${case_log%|handled}" 2000 600)
    arm_worker_wait "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    case "$case_log" in
      *'|handled')
        mkdir -p "$state/wedge.inbox/handled"
        printf 'schema=fm-task-inbox.v1\n--\nthe key is in the vault\n' > "$state/wedge.inbox/handled/001.msg"
        ;;
    esac
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an ended or supervisor-owned blocker never escalated: ${case_log}: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the ended-blocker escalation"
    grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
      || fail "an ended or supervisor-owned blocker did not keep the ladder: ${case_log}: $(cat "$out")"
  done
  pass "in an armed home a worker's own open newest blocker or decision is deferred to the bounded recheck, and a newer line, a resolved line, a reserved key, or a newer acknowledged inbox record keeps the ladder"
}

# Absent config/wedge-defer-worker-wait the same aged blocker escalates with the
# byte-identical reason it had before this evidence existed, and writes no
# recheck throttle.
test_wedge_threshold_worker_wait_is_off_until_armed() {
  local dir state fakebin out capture window key
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture worker-blocker-unarmed 'blocked: need the API key for the staging account' 2000 600)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  [ ! -e "$dir/config/wedge-defer-worker-wait" ] \
    || fail "the unarmed fixture armed the flag, so it proves nothing"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "an unarmed home stopped escalating a worker blocker: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the unarmed worker-blocker escalation"
  grep -Ex 'stale: test:fm-wedge \(idle [0-9]+s, possible wedge, escalation 1\)' "$out" >/dev/null \
    || fail "an unarmed home changed the wedge reason for a worker blocker: $(cat "$out")"
  grep -F 'declared blocker' "$out" >/dev/null \
    && fail "an unarmed home deferred a worker blocker: $(cat "$out")"
  [ ! -e "$state/.waiting-resurfaced-$key" ] \
    || fail "an unarmed home wrote the worker-wait recheck throttle"
  pass "with config/wedge-defer-worker-wait absent a worker blocker keeps the byte-identical wedge reason"
}

test_wedge_threshold_defers_to_an_executing_validation_run() {
  local dir state fakebin out capture window key n verdict step queued
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  for step in running fixing; do
    verdict="state: working · source: run-step · validating ($step) · run: 01RUNLIVE"
    dir=$(wedge_threshold_fixture "validating-$step" 'working: handed to validation' 0)
    arm_validating "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    n=1
    while [ "$n" -le 3 ]; do
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
        || fail "a $step validation run wedge-escalated at threshold $n: $(cat "$out")"
      n=$((n + 1))
    done
    [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
      || fail "a $step validation run queued a stale wake: $(cat "$state/.wake-queue")"
    grep -F 'possible wedge' "$out" >/dev/null \
      && fail "a $step validation run was reported as a possible wedge: $(cat "$out")"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "a $step validation run counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"
    [ "$(cat "$state/.validating-since-$key" 2>/dev/null || true)" = 01RUNLIVE ] \
      || fail "the $step deferral chain was not bound to its run"
  done

  # The deferral is bounded, not a cancellation: a run record that keeps saying
  # running for longer than the recheck cadence is rechecked once, worded as the
  # validating run it is rather than as a wedge, and then quiet again.
  # The wedge timer is pre-armed so the first poll is already at the threshold
  # rather than a timer repair, which would restart the chain under test.
  verdict='state: working · source: run-step · validating (running) · run: 01RUNLIVE'
  dir=$(wedge_threshold_fixture validating-aged 'working: handed to validation' 0 5)
  arm_validating "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf '01RUNLIVE' > "$state/.validating-since-$key"
  set_mtime "$(( $(date +%s) - 2000 ))" "$state/.validating-since-$key"
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" exit \
    || fail "a validation run older than the recheck cadence was never rechecked: $(cat "$out")"
  grep -F 'no-mistakes run 01RUNLIVE validating (running)' "$out" >/dev/null \
    || fail "the validating recheck did not name its run: $(cat "$out")"
  grep -F 'rechecked on a long cadence not a wedge; confirm the run is still progressing' "$out" >/dev/null \
    || fail "the validating recheck lost its action: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "the validating recheck was worded as a possible wedge: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the validating recheck"
  queued=$(wedge_stale_wakes "$state" "$window")
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
    || fail "the validating recheck repeated inside its cadence: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq "$queued" ] \
    || fail "the validating recheck queued a further wake inside its cadence"

  # A replacement run starts its own chain, so an old run's age cannot make the
  # new one re-surface at once.
  dir=$(wedge_threshold_fixture validating-new-run 'working: handed to validation' 0 5)
  arm_validating "$dir"
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  printf '01RUNOLD' > "$state/.validating-since-$key"
  set_mtime "$(( $(date +%s) - 2000 ))" "$state/.validating-since-$key"
  FM_TEST_PAUSE_RESURFACE=240 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" absorb \
    || fail "a replacement run inherited the previous run's recheck age: $(cat "$out")"
  [ "$(cat "$state/.validating-since-$key")" = 01RUNLIVE ] \
    || fail "a replacement run did not rebind the deferral chain"
  pass "a running or fixing validation run is deferred on the long recheck cadence rather than wedge-escalated"
}

# Every run state that does not prove a round is executing keeps the unchanged
# ladder even where the flag is armed: a parked gate, a terminal run, a ci
# monitor, a coarse ledger row, a verdict naming no run, no run at all, and an
# unreadable verdict.
test_wedge_threshold_escalates_when_no_run_is_executing() {
  local dir state fakebin out capture window key n spec name verdict
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for spec in \
    'parked|state: parked · source: run-step · parked at awaiting_approval: 2 finding(s) · run: 01RUNLIVE' \
    'failed|state: failed · source: run-step · run failed · run: 01RUNLIVE' \
    'done|state: done · source: run-step · checks green: PR ready for review · run: 01RUNLIVE' \
    'ci|state: working · source: run-step · ci running · run: 01RUNLIVE' \
    'coarse|state: working · source: run-step · validating (background run)' \
    'runless|state: working · source: run-step · validating (running)' \
    'absent|state: working · source: pane · busy' \
    'unreadable|error: no-mistakes status timed out'; do
    name=${spec%%|*}; verdict=${spec#*|}
    dir=$(wedge_threshold_fixture "not-executing-$name" 'working: handed to validation' 0)
    arm_validating "$dir"
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    n=1
    while [ "$n" -le 3 ]; do
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" exit \
        || fail "a $name run stopped escalating at threshold $n: $(cat "$out")"
      ack_stopped_cycle "$state" || fail "could not acknowledge $name escalation $n"
      grep -F "possible wedge, escalation $n" "$out" >/dev/null \
        || fail "a $name run did not reach escalation $n: $(cat "$out")"
      n=$((n + 1))
    done
    grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
      || fail "a $name run lost the demand-deep-inspection wording: $(cat "$out")"
    [ ! -e "$state/.validating-since-$key" ] \
      || fail "a $name run started a validating deferral chain"
  done
  pass "parked, terminal, ci-monitoring, coarse, runless, absent and unreadable runs keep the unchanged wedge ladder"
}

# Absent config/wedge-defer-validating an executing run is no deferral at all:
# the lane escalates on the unchanged schedule and wording, and the consult is
# never reached, so no current-state read is spent and no chain is started.
test_wedge_threshold_validating_run_is_off_until_armed() {
  local dir state fakebin out capture window key n probes
  local verdict='state: working · source: run-step · validating (running) · run: 01RUNLIVE'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture validating-unarmed 'working: handed to validation' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  [ ! -e "$dir/config/wedge-defer-validating" ] \
    || fail "the unarmed fixture armed the flag, so it proves nothing"
  export FM_FAKE_CREW_STATE_LOG="$dir/crew-state.calls"
  : > "$FM_FAKE_CREW_STATE_LOG"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$verdict" exit \
      || fail "an unarmed home stopped escalating a running validation at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge unarmed validating escalation $n"
    grep -F "possible wedge, escalation $n" "$out" >/dev/null \
      || fail "an unarmed home did not reach escalation $n: $(cat "$out")"
    n=$((n + 1))
  done
  probes=$(wc -l < "$FM_FAKE_CREW_STATE_LOG" | tr -d ' ')
  unset FM_FAKE_CREW_STATE_LOG
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row' "$out" >/dev/null \
    || fail "an unarmed home lost the demand-deep-inspection wording: $(cat "$out")"
  [ "$probes" -eq 0 ] \
    || fail "an unarmed home spent $probes current-state read(s) on a running validation over three thresholds"
  [ ! -e "$state/.validating-since-$key" ] \
    || fail "an unarmed home started a validating deferral chain"
  pass "with config/wedge-defer-validating absent a running validation keeps the unchanged ladder, wording and reads"
}

# The `by <ISO>` spelling is the same declaration: a worker waiting on a
# pipeline gate writes "... drive return by 2026-10-24T23:02Z", and while that
# deadline went unread the watcher only reached the wait on the flat cadence
# (2026-10-25 daily velocity audit, PR 1597).
test_paused_by_deadline_is_rechecked_like_until() {
  local dir state
  dir=$(paused_until_fixture by-passed "$(( $(date +%s) - 30 ))" 60 by); state="$dir/state"
  until_watch "$dir" 999
  wait_for_exit "$UNTIL_PID" 100 \
    || { reap "$UNTIL_PID"; fail "a declared wait whose by time passed was not rechecked ahead of the cadence"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null \
    || fail "the by-deadline recheck did not print a stale wake: $(cat "$dir/watch.out")"
  grep -F 'declared clearing time has passed' "$dir/watch.out" >/dev/null \
    || fail "the by-deadline recheck did not say the declared time passed: $(cat "$dir/watch.out")"
  reap "$UNTIL_PID"
  pass "a paused wait naming its deadline with by is rechecked at that time, not on the flat cadence"
}

test_paused_bg_job_without_until_stays_silent_after_the_job_ends() {
  local dir state
  dir=$(bg_job_paused_case bg-job-no-until \
    "paused [key=nightly-build] [at=$(date +%s)]: nightly build; resume when the job finishes")
  state="$dir/state"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked exit \
    || fail "first sight of a worker paused on its background job did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first-sight alert"
  printf '[bg failed] nightly build - Exited with code 1' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "the ended job surfaced although the declaration names no time"
  [ "$(bg_job_stale_wakes "$state")" -eq 0 ] \
    || fail "the ended job surfaced inside the cadence although the declaration names no time"
  pass "without until, a worker paused on its own ended background job is not rechecked inside the cadence"
}

test_paused_bg_job_until_timeout_rechecks_after_the_job_ends() {
  local dir state started
  started=$(date +%s)
  dir=$(bg_job_paused_case bg-job-until-running \
    "paused [key=nightly-build] [at=$started]: nightly build (background job, 600s timeout); resume when it ends, until $(iso_utc_at "$(( started + 600 ))")")
  state="$dir/state"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "a worker paused on its running background job woke before the job's timeout"
  [ "$(bg_job_stale_wakes "$state")" -eq 0 ] || fail "the running job surfaced before its timeout"
  started=$(( $(date +%s) - 180 ))
  dir=$(bg_job_paused_case bg-job-until \
    "paused [key=nightly-build] [at=$started]: nightly build (background job, 120s timeout); resume when it ends, until $(iso_utc_at "$(( started + 120 ))")")
  state="$dir/state"
  printf '[bg failed] nightly build - Exited with code 1' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked exit \
    || fail "the job's timeout passed without a recheck of the worker paused on it"
  [ "$(bg_job_stale_wakes "$state")" -eq 1 ] || fail "the passed timeout queued the wrong number of rechecks"
  awk -F '\t' '$3 == "stale" && $5 == "stale: test:fm-parked" { found = 1 } END { exit !found }' \
    "$state/.wake-queue" || fail "the recheck carried an unexpected reason: $(cat "$state/.wake-queue")"
  case "$(cat "$state/.paused-resurfaced-test_fm-parked" 2>/dev/null)" in
    *:due) ;;
    *) fail "the recheck was not recorded as the passed declared time" ;;
  esac
  ack_stopped_cycle "$state" || fail "could not acknowledge the due recheck"
  printf '[bg failed] nightly build - Exited with code 1 (idle)' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "the due recheck repeated instead of returning to the cadence"
  pass "until set to a background job's timeout rechecks the worker paused on it once the job must have ended"
}

test_exit_picker_stale_names_the_dialog() {
  local dir state fakebin out capture_file window key pid count_file
  dir=$(make_case exit-picker-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; count_file="$dir/captures"
  window="test:fm-picker"
  write_exit_picker "$capture_file"
  key=$(prime_picker_window "$state" picker "$window" ship "$capture_file" 'working: parked between turns')
  printf '0\n' > "$count_file"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$count_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a pane parked on the exit picker: $(cat "$out")"
  grep -F "stale: $window" "$out" >/dev/null || fail "the picker wake was not a stale wake: $(cat "$out")"
  grep -F 'blocked-on-prompt: Claude background-task exit picker' "$out" >/dev/null \
    || fail "the picker wake did not name the dialog: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null && fail "the first picker stale was labeled a wedge: $(cat "$out")"
  [ "$(cat "$count_file")" -eq 1 ] || fail "the picker poll captured the pane $(cat "$count_file") times"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$(hash_text "$(cat "$capture_file")")" ] \
    || fail "the picker stale did not record the pane hash"
  unset FM_FAKE_CREW_STATE
  pass "a pane on the exit picker is a named stale, from the one capture the poll already takes"
}

test_exit_picker_wedge_keeps_climbing() {
  local dir state fakebin out capture_file window key pid n
  dir=$(make_case exit-picker-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-picker-wedge"
  write_exit_picker "$capture_file"
  key=$(prime_picker_window "$state" picker "$window" ship "$capture_file" 'working: parked between turns')
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a working pane on the picker exited instead of keeping the wedge timer: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a working pane on the picker woke before the wedge timer: $(cat "$out")"
  [ -s "$state/.stale-since-$key" ] || fail "the picker did not start the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the picker absorb"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first picker wedge did not escalate: $(cat "$out")"
  grep -F 'possible wedge, escalation 1' "$out" >/dev/null || fail "the first picker wedge lost its count: $(cat "$out")"
  grep -F 'blocked-on-prompt: Claude background-task exit picker' "$out" >/dev/null \
    || fail "the first picker wedge dropped the dialog name: $(cat "$out")"
  grep -F 'demand-deep-inspection' "$out" >/dev/null && fail "escalation 1 demanded inspection: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge picker escalation 1"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the third picker wedge did not escalate: $(cat "$out")"
  grep -F 'possible wedge, escalation 3' "$out" >/dev/null || fail "the ladder did not reach escalation 3: $(cat "$out")"
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone, blocked-on-prompt: Claude background-task exit picker' \
    "$out" >/dev/null || fail "the dialog name was not after demand-deep-inspection: $(cat "$out")"
  n=$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)
  [ "$n" -eq 3 ] || fail "the escalation count was $n, not 3"
  unset FM_FAKE_CREW_STATE
  pass "a pane on the exit picker keeps the wedge ladder, and the name follows demand-deep-inspection"
}

test_quoted_exit_picker_stays_ordinary_stale() {
  local dir state fakebin out capture_file window pid
  dir=$(make_case quoted-exit-picker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quoted"
  write_quoted_exit_picker "$capture_file"
  prime_picker_window "$state" quoted "$window" ship "$capture_file" 'working: parked between turns' >/dev/null
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a quoted picker did not take the ordinary stale path: $(cat "$out")"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "a quoted picker was not an ordinary stale: $(cat "$out")"
  grep -F 'blocked-on-prompt' "$out" >/dev/null && fail "a quoted picker was named as a dialog: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "picker text quoted above a composer stays an ordinary stale"
}

test_secondmate_exit_picker_stays_quiet() {
  local dir state fakebin out capture_file window pid count_file
  dir=$(make_case secondmate-exit-picker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; count_file="$dir/captures"
  window="test:fm-picker-mate"
  write_exit_picker "$capture_file"
  prime_picker_window "$state" mate "$window" secondmate "$capture_file" 'working: the parent supervises this secondmate' >/dev/null
  printf '0\n' > "$count_file"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$count_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a second mate on the exit picker woke: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a second mate on the exit picker printed a wake: $(cat "$out")"; }
  [ "$(cat "$count_file")" -eq 0 ] \
    || { reap "$pid"; fail "a second mate on the exit picker was captured $(cat "$count_file") times"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a second mate on the exit picker stays quiet, and the poll does not capture the pane"
}

# The away daemon saved this name while the picker was up. Once the pane leaves
# it, the same capture the stale path already takes has to drop the name, or
# the persistence line would still say the dialog is open.
test_closed_exit_picker_drops_saved_dialog_name() {
  local dir state fakebin out capture_file window pid
  dir=$(make_case exit-picker-closed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-picker-closed"
  printf 'idle at the prompt\n' > "$capture_file"
  prime_picker_window "$state" closer "$window" ship "$capture_file" 'working: parked between turns' >/dev/null
  printf '%s' 'Claude background-task exit picker' > "$state/.subsuper-dialog-closer"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a closed picker did not take the ordinary stale path: $(cat "$out")"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "a closed picker was not an ordinary stale: $(cat "$out")"
  grep -F 'blocked-on-prompt' "$out" >/dev/null && fail "a closed picker was still named as a dialog: $(cat "$out")"
  [ ! -e "$state/.subsuper-dialog-closer" ] || fail "a closed picker left the saved dialog name"
  unset FM_FAKE_CREW_STATE
  pass "a closed picker drops the saved dialog name, and the stale stays ordinary"
}

# The rearm-resurface starvation: a watcher restart with one unacknowledged row
# left in the durable queue used to reopen the announced recovery episode
# because the queue was merely non-empty, mint a fresh generation, and resurface
# again - every turn end, while .last-check froze and no due check ever ran.
test_unacknowledged_row_does_not_stop_last_check_advancing() {
  local dir state fakebin out check_file pid announced
  dir=$(make_case rearm-starve)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  check_file="$state/task.check.sh"
  # Empty output: the check runs and advances .last-check without appending a
  # queue row, so the queue stays unchanged across every cycle below.
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register the due custom check"
  append_wake "$state" signal task 'signal: task.status' \
    || fail "the unacknowledged row could not be queued"

  # The first start announces the fresh pending episode - the one legitimate
  # resurface; the check block sits behind the resurface wake and cannot run.
  watch_bg "$state" "$fakebin" "$out" env -u CLAUDE_CODE_SESSION_ID FM_CHECK_INTERVAL=0
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "the first watcher never surfaced its announce: $(cat "$out")"; }
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "fixture: the first watcher did not announce the fresh episode: $(cat "$out")"
  announced=$(cat "$state/.watcher-down")

  # A restart over the unchanged queue must not resurface again: the watcher
  # cycles quietly, and its due check advances .last-check.
  watch_bg "$state" "$fakebin" "$out" env -u CLAUDE_CODE_SESSION_ID FM_CHECK_INTERVAL=0
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "the restarted watcher exited instead of cycling quietly: $(cat "$out")"; }
  [ ! -s "$out" ] \
    || { reap "$pid"; fail "the restart resurfaced the unchanged queue: $(cat "$out")"; }
  [ -e "$state/.last-check" ] \
    || { reap "$pid"; fail "the restart did not advance .last-check"; }

  # Repeated cycles keep the same hold: no resurface, cadence still advancing,
  # the episode still the generation the first start announced.
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "the restarted watcher exited during its later cycles: $(cat "$out")"; }
  reap "$pid"
  [ "$(cat "$state/.watcher-down")" = "$announced" ] \
    || fail "a restart reopened the announced episode: $announced -> $(cat "$state/.watcher-down")"
  grep -F "$(printf '\tsignal\ttask\t')" "$state/.wake-queue" >/dev/null \
    || fail "the unacknowledged row vanished from the durable queue"
  pass "an unchanged unacknowledged row never stops .last-check advancing"
}

# Genuinely new queued work must still resurface once: a row appended after the
# announcement opens a fresh episode on the next start, and that second episode
# must not loop either once its own queue is unchanged.
test_row_appended_after_announcement_still_resurfaces() {
  local dir state fakebin out pid announced reopened
  dir=$(make_case rearm-late-row)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  append_wake "$state" signal task 'signal: task.status' \
    || fail "the unacknowledged row could not be queued"

  watch_bg "$state" "$fakebin" "$out" env -u CLAUDE_CODE_SESSION_ID
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "the first watcher never surfaced its announce: $(cat "$out")"; }
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "fixture: the first watcher did not announce the fresh episode: $(cat "$out")"
  announced=$(cat "$state/.watcher-down")

  # A row appended after the announcement advances the queue's append sequence.
  append_wake "$state" signal late 'signal: late arriving work' \
    || fail "the late row could not be queued"

  # The next start must resurface the new work once, under a fresh generation.
  watch_bg "$state" "$fakebin" "$out" env -u CLAUDE_CODE_SESSION_ID
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "the restarted watcher never surfaced the late row: $(cat "$out")"; }
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "a row appended after the announcement did not resurface: $(cat "$out")"
  reopened=$(cat "$state/.watcher-down")
  [ "$reopened" != "$announced" ] \
    || fail "the late row resurfaced under the old generation instead of a fresh one"

  # The second episode must not loop over its own unchanged queue either.
  watch_bg "$state" "$fakebin" "$out" env -u CLAUDE_CODE_SESSION_ID
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "the watcher after the resurface exited instead of cycling quietly: $(cat "$out")"; }
  [ ! -s "$out" ] \
    || { reap "$pid"; fail "an unchanged queue resurfaced a second time: $(cat "$out")"; }
  reap "$pid"
  pass "a row appended after the announcement resurfaces once under a fresh generation"
}

# On a Claude primary every turn end re-arms the watcher, and each restart used
# to mint a fresh recovery generation over the unchanged queue - so a hand-typed
# acknowledgement between turns was refused as "a newer recovery episode is
# pending". With the episode staying announced across restarts, the generation a
# wake presented must still be acknowledgeable after any number of them.
test_ack_between_restarts_is_not_refused_as_newer_episode() {
  local dir state fakebin out pid generation err
  dir=$(make_case rearm-ack)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; err="$dir/ack.err"
  append_wake "$state" signal task 'signal: task.status' \
    || fail "the unacknowledged row could not be queued"

  watch_bg "$state" "$fakebin" "$out" env -u CLAUDE_CODE_SESSION_ID
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "the first watcher never surfaced its announce: $(cat "$out")"; }
  generation=$(cat "$state/.watcher-down")
  generation=${generation##*:}
  [ -n "$generation" ] || fail "the announce left no generation to acknowledge"

  # Two restarts over the unchanged queue: exactly what turn-end re-arms do.
  watch_bg "$state" "$fakebin" "$out" env -u CLAUDE_CODE_SESSION_ID
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "the first restart exited instead of cycling quietly: $(cat "$out")"; }
  reap "$pid"
  watch_bg "$state" "$fakebin" "$out" env -u CLAUDE_CODE_SESSION_ID
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "the second restart exited instead of cycling quietly: $(cat "$out")"; }
  reap "$pid"

  # The acknowledgement a wake presentation printed must still land.
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 1 --recovery-generation "$generation" \
    >/dev/null 2> "$err" || fail "the between-restarts acknowledgement failed: $(cat "$err")"
  if grep -F 'newer recovery episode is pending' "$err" >/dev/null; then
    fail "the restarts minted a newer episode over the unchanged queue: $(cat "$err")"
  fi
  case "$(cat "$state/.watcher-down")" in
    acked:downtime:"$generation") ;;
    *) fail "the acknowledged generation was not retired: $(cat "$state/.watcher-down")" ;;
  esac
  [ ! -s "$state/.wake-queue" ] || fail "the acknowledgement did not consume the queued row"
  pass "an acknowledgement typed between restarts retires the generation it names"
}

test_recovery_rearm_depends_only_on_queue_sequence() {
  local dir state phase sequence identity
  dir=$(make_case rearm-sequence)
  for phase in announced acked; do
    for sequence in same higher regressed missing-record empty-record invalid-record missing-live empty-live invalid-live; do
      for identity in same different absent; do
        state="$dir/$phase-$sequence-$identity"
        FM_STATE_OVERRIDE="$state" CLAUDE_CODE_SESSION_ID=first bash -s -- \
          "$ROOT/bin/fm-wake-lib.sh" "$phase" "$sequence" "$identity" <<'SH' \
          || fail "$phase re-arm violated sequence contract: $sequence, $identity identity"
set -eu
. "$1"
marker="$STATE/.watcher-down"
fm_wake_append signal task 'signal: task.status'
fm_recovery_marker_arm_check "$marker"
[ "$FM_RECOVERY_MARKER_ACTION" = recover ]
[ "$(cat "$marker.announce-seq")" = 1 ]
generation=${FM_RECOVERY_MARKER_TOKEN##*:}
if [ "$2" = acked ]; then
  fm_recovery_marker_ack "$marker" "$generation"
fi
before=$(cat "$marker")
case "$3" in
  higher) printf '2\n' > "$STATE/.wake-queue.seq" ;;
  regressed) printf '0\n' > "$STATE/.wake-queue.seq" ;;
  missing-record) rm "$marker.announce-seq" ;;
  empty-record) : > "$marker.announce-seq" ;;
  invalid-record) printf 'invalid\n' > "$marker.announce-seq" ;;
  missing-live) rm "$STATE/.wake-queue.seq" ;;
  empty-live) : > "$STATE/.wake-queue.seq" ;;
  invalid-live) printf 'invalid\n' > "$STATE/.wake-queue.seq" ;;
esac
case "$4" in
  different) export CLAUDE_CODE_SESSION_ID=second ;;
  absent) unset CLAUDE_CODE_SESSION_ID ;;
esac
fm_recovery_marker_reopen_announced "$marker"
fm_recovery_marker_arm_check "$marker"
if [ "$3" = same ]; then
  [ "$(cat "$marker")" = "$before" ]
  [ "$FM_RECOVERY_MARKER_ACTION" != recover ]
else
  [ "$FM_RECOVERY_MARKER_ACTION" = recover ]
  [ "$(cat "$marker")" != "$before" ]
  case "$(cat "$marker")" in announced:downtime:*) ;; *) exit 1 ;; esac
  [ "$(cat "$marker.announce-seq")" = "$(cat "$STATE/.wake-queue.seq" 2>/dev/null || true)" ]
fi
SH
      done
    done
  done
  pass "recovery re-arms follow only queue sequence changes across identities and episode states"
}

test_unknown_alive_stale_is_bounded_after_its_first_alarm
test_unknown_alive_stale_without_progress_keeps_surfacing
test_wedge_guards_absent_config_keeps_the_unchanged_ladder
test_wedge_guard_critical_defers_one_window_at_a_time_up_to_the_cap
test_wedge_guard_failures_fail_open
test_wedge_guard_never_defers_a_gone_endpoint
test_wedge_threshold_defers_to_a_backlog_captain_hold
test_wedge_threshold_defers_to_a_worker_blocker
test_wedge_threshold_worker_wait_is_off_until_armed
test_wedge_threshold_defers_to_an_executing_validation_run
test_wedge_threshold_escalates_when_no_run_is_executing
test_wedge_threshold_validating_run_is_off_until_armed
test_paused_by_deadline_is_rechecked_like_until
test_paused_bg_job_without_until_stays_silent_after_the_job_ends
test_paused_bg_job_until_timeout_rechecks_after_the_job_ends
test_exit_picker_stale_names_the_dialog
test_exit_picker_wedge_keeps_climbing
test_quoted_exit_picker_stays_ordinary_stale
test_secondmate_exit_picker_stays_quiet
test_closed_exit_picker_drops_saved_dialog_name
test_unacknowledged_row_does_not_stop_last_check_advancing
test_row_appended_after_announcement_still_resurfaces
test_ack_between_restarts_is_not_refused_as_newer_episode
test_recovery_rearm_depends_only_on_queue_sequence
