#!/usr/bin/env bash
# tests/fm-branch-mod-bin.test.sh - the bin surface behind the Claude Code
# supervision-branch mod (docs/claude-supervision-branch.md): the classifier
# evidence bundle and its per-task offset, the routine-covered backstop
# extension of the main drain, the classification-log scorer, and the shadow
# advisory helpers (the jev call shim, the bounded pane reader, and the
# shadow-log scorer); teardown of the offset file is covered by
# tests/fm-teardown.test.sh. Every piece is inert without state/.branch-mod-mode.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
EVIDENCE="$ROOT/bin/fm-wake-evidence.sh"
OUTCOMES="$ROOT/bin/fm-branch-outcome.sh"
SCORE="$ROOT/bin/fm-branch-classifier-score.sh"
JEV="$ROOT/bin/fm-branch-shadow-jev.sh"
PANE="$ROOT/bin/fm-branch-shadow-pane.sh"
SSCORE="$ROOT/bin/fm-branch-shadow-score.sh"
GATES="$ROOT/bin/fm-branch-shadow-gates.sh"
# shellcheck disable=SC2034 # make_case reads it
TMP_ROOT=$(fm_test_tmproot fm-branch-mod-bin-tests)

set_mtime() {  # <epoch> <file>
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

append_outcome() {  # <state> <task> <verdict> <summary>
  FM_STATE_OVERRIDE="$1" "$OUTCOMES" append \
    --task "$2" --verdict "$3" --summary "$4" >/dev/null
}

backstop_body() {  # <drain-output>
  awk '
    /^STATUS OUTCOME BACKSTOP \(/ { in_section=1; next }
    in_section && /^(OPEN DECISIONS|RECORD DIVERGENCE|UNREAD STATUS|WAKE_ACK_REQUIRED)/ { exit }
    in_section { print }
  ' "$1"
}

test_gates_scorer_joins_full_records_to_outcomes_facts_and_derivable_actions() {
  local dir state out lines
  dir=$(make_case gates-scorer)
  state="$dir/state"
  out="$dir/gates.out"
  local sev_classes='["False alarm or no functional impact","Routine recoverable interruption or non-blocking failure","Task blocked or failed after normal recovery","Security, privacy, data-loss, irreversible, credential, or external-publication impact"]'
  local base_t=1700000000

  append_wake_outcome() {  # <state> <task> <verdict> <summary> <wakeKey>
    FM_STATE_OVERRIDE="$1" "$OUTCOMES" append \
      --task "$2" --verdict "$3" --summary "$4" --wake-key "$5" >/dev/null
  }

  fact() {  # <wk> <bytes-json> <pane> <pr-json> [extra-json-fields]
    printf '{"wake_key":"%s","new_status_bytes":%s,"pane":"%s","authoritative_pr":%s,"severity_classes":%s%s}' \
      "$1" "$2" "$3" "$4" "$sev_classes" "${5:+,$5}"
  }
  obs_prog='{"progressing":true,"busy_source":"tmux","seconds_since_last_activity":5}'
  stale_extra="\"stale_series\":{\"series_index\":3},\"pane_observation\":$obs_prog"
  rec() {  # <wakeKey> <t-offset> <wake> <tasks-json> <answers-json> <facts-json-or-null>
    printf '%s\n' "{\"t\":\"$(date -u -d "@$((base_t + $2))" +%Y-%m-%dT%H:%M:%SZ)\",\"kind\":\"shadow\",\"wake\":\"$3\",\"seqs\":[\"1\"],\"wakeKey\":\"$1\",\"tasks\":$4,\"wakeNo\":1,\"variant\":\"full\",\"repeat\":1,\"control\":false,\"unavailable\":null,\"requestBytes\":10,\"ms\":5,\"policy\":{\"choice_confidence_floor\":0.85,\"noul_grant_below\":0.15,\"noul_pass_above\":0.85},\"answers\":$5,\"facts\":$6}"
  }

  # Task fixtures: metas for every task (t1 carries a recorded PR), plain
  # status logs so the appender's endpoints are the whole log.
  printf 'id=t1\nwindow=fm-t1\nbackend=tmux\npr=https://github.com/ow/repo/pull/7\n' > "$state/t1.meta"
  printf 'id=t2\nwindow=fm-t2\nbackend=tmux\n' > "$state/t2.meta"
  printf 'id=t3\nwindow=fm-t3\nbackend=tmux\n' > "$state/t3.meta"
  printf 'id=t4\nwindow=fm-t4\nbackend=tmux\n' > "$state/t4.meta"
  printf 'id=t5\nwindow=fm-t5\nbackend=tmux\n' > "$state/t5.meta"
  printf 'id=t6\nwindow=fm-t6\nbackend=tmux\n' > "$state/t6.meta"
  printf 'working: on it\n' > "$state/t1.status"
  printf 'working: t2\n' > "$state/t2.status"
  printf 'working: t3\n' > "$state/t3.status"
  printf 'working: t5\n' > "$state/t5.status"
  printf 'working: t6\n' > "$state/t6.status"
  printf 'id=t7\nwindow=fm-t7\nbackend=tmux\n' > "$state/t7.meta"
  printf 'working: t7\n' > "$state/t7.status"
  printf 'id=t8\nwindow=fm-t8\nbackend=tmux\n' > "$state/t8.meta"
  # A captain line presented before the mod's first row on t8: the first
  # row's span is never scanned, so it is not a backstop surfacing.
  printf 'done: t8 finished before the trial\n' > "$state/t8.status"
  # A worker incarnation newer than the 1700:10 stale wake: the derivable
  # stale-repair signal for the suppression gate.
  printf 'v1 gen=g%s.4242.17 seq=1 state=busy source=tmux event=turn-end ts=%s\n' "$((base_t + 50))" "$((base_t + 50))" > "$state/t5.busy-state"

  # Ground truth rows, in an order that also fixes first-reported ordering
  # for the candidate-order gate.
  append_wake_outcome "$state" t1 routine 'signal noted' 1700:1
  append_wake_outcome "$state" t1 routine 'signal noted' 1700:2
  append_wake_outcome "$state" t1 captain 'escalated to main' 1700:3
  printf 'done: PR https://github.com/ow/repo/pull/77 checks green\n' >> "$state/t1.status"
  append_wake_outcome "$state" t1 routine 'branch judged the completion routine' 1700:4
  append_wake_outcome "$state" t1 captain 'done: PR https://github.com/ow/repo/pull/7 checks green' 1700:5
  append_wake_outcome "$state" t2 routine 'working as usual' 1700:6
  append_wake_outcome "$state" t3 routine 'worker fine' 1700:7
  append_wake_outcome "$state" t3 routine 'worker fine' 1700:8
  append_wake_outcome "$state" t3 captain 'stale escalated' 1700:9
  append_wake_outcome "$state" t5 routine 'stale but fine' 1700:10
  append_wake_outcome "$state" t2 captain 'compound: t2 escalated' 1700:11
  append_wake_outcome "$state" t1 routine 'compound: t1 noted' 1700:11
  append_wake_outcome "$state" t2 captain 'compound: t2 escalated' 1700:12
  append_wake_outcome "$state" t1 routine 'compound: t1 noted' 1700:12
  append_wake_outcome "$state" t1 routine 'nofacts noted' 1700:13
  # An unkeyed direct pass-to-main row covers t6's done line before the
  # keyed routine row, so the later row's backstop span starts after it.
  printf 'done: t6 finished\n' >> "$state/t6.status"
  append_outcome "$state" t6 captain 'Passed to main directly (classifier): decision'
  append_wake_outcome "$state" t6 routine 'noise' 1700:15
  append_wake_outcome "$state" t3 routine 'stale, pane unread' 1700:16
  append_wake_outcome "$state" t7 routine 'stale but fine, torn down later' 1700:17
  append_wake_outcome "$state" t8 routine 'first row on t8' 1700:18
  append_wake_outcome "$state" t2 captain 'compound stale: t2 escalated' 1700:19
  append_wake_outcome "$state" t1 routine 'compound stale: t1 noted' 1700:19
  append_wake_outcome "$state" t2 captain 'stale again' 1700:20
  append_wake_outcome "$state" t8 routine 'gather failed' 1700:21
  rm -f "$state/t7.meta" "$state/t7.status"

  {
    rec 1700:1 0 'signal: A' '["t1"]' '{"no_new_outcome":{"type":"noul","noul":0.9}}' "$(fact 1700:1 '{"t1":0}' fm-t1 '{"present":false}')"
    rec 1700:2 1 'signal: A' '["t1"]' '{"no_new_outcome":{"type":"noul","noul":0.5}}' "$(fact 1700:2 '{"t1":0}' fm-t1 '{"present":false}')"
    rec 1700:3 2 'working: A' '["t1"]' '{"route":{"type":"choice","choice":"routine","confidence":0.9},"phase":{"type":"choice","choice":"working","confidence":0.9}}' "$(fact 1700:3 '{"t1":10}' fm-t1 '{"present":false}')"
    rec 1700:4 3 'signal: A' '["t1"]' '{"no_new_outcome":{"type":"noul","noul":0.95},"severity":{"type":"score","score":1,"confidence":0.9}}' "$(fact 1700:4 '{"t1":0}' fm-t1 '{"present":false}')"
    rec 1700:5 4 'working: A' '["t1"]' '{"phase":{"type":"choice","choice":"finished_ready","confidence":0.92}}' "$(fact 1700:5 '{"t1":10}' fm-t1 '{"present":true,"pr":"ow/repo#7"}')"
    rec 1700:6 5 'working: B' '["t2"]' '{"phase":{"type":"choice","choice":"finished_ready","confidence":0.92}}' "$(fact 1700:6 '{"t2":10}' fm-t2 '{"present":true,"pr":"ow/repo#9"}')"
    rec 1700:7 6 'stale: fm-t3' '["t3"]' '{"stale_state":{"type":"choice","choice":"active","confidence":0.9}}' "$(fact 1700:7 '{"t3":0}' fm-t3 '{"present":false}' "$stale_extra")"
    rec 1700:8 0 'stale: fm-t4' '["t4"]' '{"stale_state":{"type":"choice","choice":"active","confidence":0.9}}' "$(fact 1700:8 '{"t4":0}' fm-t4 '{"present":false}' "$stale_extra")"
    rec 1700:9 60 'stale: fm-t4' '["t4"]' '{"stale_state":{"type":"choice","choice":"active","confidence":0.9}}' "$(fact 1700:9 '{"t4":0}' fm-t4 '{"present":false}' "$stale_extra")"
    rec 1700:10 0 'signal: t5\nstale: fm-t5' '["t5"]' '{"stale_state":{"type":"choice","choice":"active","confidence":0.9}}' "$(fact 1700:10 '{"t5":0}' fm-t5 '{"present":false}' "$stale_extra")"
    rec 1700:11 7 'signal: compound' '["t1","t2"]' '{"candidates":{"t1":{"type":"noul","noul":0.9},"t2":{"type":"noul","noul":0.5}}}' "$(fact 1700:11 '{"t1":0,"t2":0}' fm-t1 '{"present":false}' '"candidates":{"t1":0.9,"t2":0.5}')"
    rec 1700:12 8 'signal: compound' '["t1","t2"]' '{"candidates":{"t2":{"type":"noul","noul":0.9},"t1":{"type":"noul","noul":0.5}}}' "$(fact 1700:12 '{"t1":0,"t2":0}' fm-t1 '{"present":false}' '"candidates":{"t2":0.9,"t1":0.5}')"
    rec 1700:13 9 'signal: nofacts' '["t1"]' '{}' 'null'
    rec 1700:14 10 'signal: unmatched' '["t6"]' '{}' "$(fact 1700:14 '{"t6":0}' fm-t6 '{"present":false}')"
    rec 1700:15 11 'signal: t6' '["t6"]' '{"severity":{"type":"score","score":3,"confidence":0.9}}' "$(fact 1700:15 '{"t6":0}' fm-t6 '{"present":false}')"
    rec 1700:16 12 'stale: fm-t3' '["t3"]' '{"stale_state":{"type":"choice","choice":"active","confidence":0.9}}' "$(fact 1700:16 '{"t3":0}' fm-t3 '{"present":false}')"
    rec 1700:17 13 'stale: fm-t7' '["t7"]' '{"stale_state":{"type":"choice","choice":"active","confidence":0.9}}' "$(fact 1700:17 '{"t7":0}' fm-t7 '{"present":false}' "$stale_extra")"
    rec 1700:18 14 'signal: t8' '["t8"]' '{"no_new_outcome":{"type":"noul","noul":0.9}}' "$(fact 1700:18 '{"t8":0}' fm-t8 '{"present":false}')"
    rec 1700:19 20 'signal: t1.status\nstale: fm-t2 (idle 900s, possible wedge, escalation 2)' '["t1","t2"]' '{"stale_state":{"type":"choice","choice":"active","confidence":0.9},"candidates":{"t2":{"type":"noul","noul":0.9},"t1":{"type":"noul","noul":0.5}}}' "$(fact 1700:19 '{"t1":0,"t2":0}' fm-t1 '{"present":false}' "$stale_extra,\"candidates\":{\"t2\":0.9,\"t1\":0.5}")"
    rec 1700:20 80 'stale: fm-t2 (idle 960s, possible wedge, escalation 3)' '["t2"]' '{"stale_state":{"type":"choice","choice":"active","confidence":0.9}}' "$(fact 1700:20 '{"t2":0}' fm-t2 '{"present":false}' "$stale_extra")"
    rec 1700:21 15 'signal: t8' '["t8"]' '{"no_new_outcome":{"type":"noul","noul":0.9},"route":{"type":"choice","choice":"routine","confidence":0.9},"phase":{"type":"choice","choice":"working","confidence":0.9}}' "$(fact 1700:21 '{}' fm-t8 '{"present":false}')"
  } > "$state/branch-mod-shadow.jsonl"

  FM_STATE_OVERRIDE="$state" "$GATES" > "$out" || fail "gates scorer failed: $(cat "$out")"
  grep -Fx '| absorb-no-new-outcome | 4 | 16 | 3 | 2 (66.7%) | 0 | 1 | 1 |' "$out" \
    || fail "the no-new-outcome row must fire the clean absorbs (including a task's first row over a pre-trial captain line), miss the below-floor one, and count the backstop-covered absorb as a loss: $(grep '^| absorb-no-new-outcome' "$out")"
  grep -Fx '| absorb-routine-working | 2 | 18 | 2 | 1 (50.0%) | 0 | 1 | 0 |' "$out" \
    || fail "the routine-working row must count a fire over a captain outcome as a loss: $(grep '^| absorb-routine-working' "$out")"
  grep -Fx '| stale-active-suppress | 6 | 2 | 6 | 2 (33.3%) | 3 | 1 | 0 |' "$out" \
    || fail "the stale gate must apply only to stale wakes whose pane fact is the named window, score the in-window captain stales as losses, its own actionable or relaunch-repaired fires as delays, and a torn-down task's fire as correct: $(grep '^| stale-active-suppress' "$out")"
  grep -Fx '| pr-ready-arm | 4 | 16 | 2 | 1 (50.0%) | 1 | 0 | 0 |' "$out" \
    || fail "the arm gate must score the armed PR ready as correct and the unbacked one as a delay: $(grep '^| pr-ready-arm' "$out")"
  grep -Fx '| severity-alert | 2 | 18 | 1 | 0 (0.0%) | 1 | 0 | 1 |' "$out" \
    || fail "the severity gate must count a security-class alert over an absorbable wake as a delay and a low-scored actionable absorb as missed: $(grep '^| severity-alert' "$out")"
  grep -Fx '| candidate-order | 3 | 0 | 3 | 2 (66.7%) | 0 | 1 | - |' "$out" \
    || fail "the ordering gate must apply only to compound wakes, count the dropped captain candidate as a loss and the matched order as correct: $(grep '^| candidate-order' "$out")"
  grep -Fx 'unmatched (no outcome row carries this wake key; never counted as a verdict): 1 record' "$out" \
    || fail "the record with no outcome rows must be reported as unmatched, not scored: $(grep unmatched "$out")"
  grep -Fx 'torn down (a task record is gone, so the merge-poll and stale-repair truth for these wakes is no longer readable): 1 record' "$out" \
    || fail "the record whose task was torn down must be noted, since its derivable actions are no longer readable: $(grep 'torn down' "$out")"
  grep -Fx '| absorb-no-new-outcome | 0.96 | 0 | 0.0% |' "$out" \
    || fail "the no-new-outcome sweep must find its clean floor above the backstop-covered Noul: $(grep '^| absorb-no-new-outcome | 0' "$out")"
  grep -Fx '| stale-active-suppress | 0.91 | 0 | 0.0% |' "$out" \
    || fail "the stale sweep must only clean above the firing confidence: $(grep '^| stale-active-suppress | 0' "$out")"
  grep -Fx '| pr-ready-arm | 0.70 | 2 | 50.0% |' "$out" \
    || fail "the arm sweep has no loss class and must clean at the lowest floor: $(grep '^| pr-ready-arm | 0' "$out")"
  grep -Fx '| candidate-order | - | - | - |' "$out" \
    || fail "the ordering sweep must stay dirty at every floor while a captain candidate sits below it: $(grep '^| candidate-order | - ' "$out")"

  FM_STATE_OVERRIDE="$state" "$GATES" -v > "$out" || fail "verbose gates scorer failed"
  grep -F $'1700:8\tstale-active-suppress\tloss\tpane=fm-t4 window=1800s' "$out" \
    || fail "the suppressing stale wake whose later in-window stale was captain must be listed as a loss: $(grep stale-active-suppress "$out")"
  grep -F $'1700:10\tstale-active-suppress\tdelay\tpane=fm-t5 window=1800s' "$out" \
    || fail "the stale wake with a derivable repair must be listed as a delay: $(grep stale-active-suppress "$out")"
  grep -F $'1700:17\tstale-active-suppress\tcorrect\tpane=fm-t7 window=1800s' "$out" \
    || fail "a later teardown is not a stale repair, so the fire stays correct: $(grep stale-active-suppress "$out")"
  grep -F $'1700:11\tcandidate-order\tloss\tcandidates=t1:0.9,t2:0.5 first_reported=t2' "$out" \
    || fail "the dropped captain candidate must be listed with the raw ordering: $(grep candidate-order "$out")"
  grep -F $'1700:12\tcandidate-order\tcorrect\tcandidates=t2:0.9,t1:0.5 first_reported=t2' "$out" \
    || fail "the matched candidate order must be listed as correct: $(grep candidate-order "$out")"
  grep -F $'1700:13\tabsorb-no-new-outcome\t' "$out" | grep -q 'missing inputs' \
    || fail "the record without facts must be listed unscorable, never guessed: $(grep 1700:13 "$out")"
  ! grep -F $'1700:13\tstale-active-suppress\t' "$out" \
    || fail "a plain wake is not unscorable at the stale gate; the gate does not apply: $(grep 1700:13 "$out")"
  ! grep -F $'1700:13\tcandidate-order\t' "$out" \
    || fail "a single-task wake is not unscorable at the ordering gate; the gate does not apply: $(grep 1700:13 "$out")"
  grep -F $'1700:19\tstale-active-suppress\t' "$out" | grep -q 'missing inputs' \
    || fail "a compound wake whose pane fact belongs to another task than the named stale window is unscorable, never judged on the wrong pane: $(grep 1700:19 "$out")"
  grep -F $'1700:21\tabsorb-no-new-outcome\t' "$out" | grep -q 'missing inputs' \
    || fail "a record whose new_status_bytes is empty has no byte count and is unscorable at the absorb gate, never a zero: $(grep 1700:21 "$out")"
  grep -F $'1700:20\tstale-active-suppress\tdelay\tpane=fm-t2 window=1800s' "$out" \
    || fail "the later captain stale on the named window is a delay on its own outcome: $(grep 1700:20 "$out")"
  grep -F $'1700:16\tstale-active-suppress\t' "$out" | grep -q 'missing inputs' \
    || fail "a stale record without a pane observation must be listed unscorable, never guessed: $(grep 1700:16 "$out")"

  grep -F $'1700:4\tabsorb-no-new-outcome\tloss' "$out" >/dev/null \
    || fail "the backstop-covered absorb must be listed as a loss while the status log is present: $(grep 1700:4 "$out")"
  [ "$(jq -r 'select(.wakeKey == "1700:4") | .backstop' "$state/.branch-shadow-truth.jsonl" | tail -1)" = 1 ] \
    || fail "the sidecar must record the live backstop surfacing: $(cat "$state/.branch-shadow-truth.jsonl")"
  lines=$(wc -l < "$state/.branch-shadow-truth.jsonl" | tr -d ' ')
  rm -f "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$GATES" -v > "$out" || fail "verbose gates scorer failed with the status log retired and the meta present"
  grep -F $'1700:4\tabsorb-no-new-outcome\tloss' "$out" >/dev/null \
    || fail "a retired status log with the meta still present must not flip the recorded backstop loss: $(grep 1700:4 "$out")"
  [ "$(wc -l < "$state/.branch-shadow-truth.jsonl" | tr -d ' ')" = "$lines" ] \
    || fail "an absent status log must never be snapshotted: $(cat "$state/.branch-shadow-truth.jsonl")"
  rm -f "$state/t1.meta"
  FM_STATE_OVERRIDE="$state" "$GATES" -v > "$out" || fail "verbose gates scorer failed after the status log was retired"
  grep -F $'1700:4\tabsorb-no-new-outcome\tloss' "$out" >/dev/null \
    || fail "a retired status log must not flip the recorded backstop loss to correct: $(grep 1700:4 "$out")"

  FM_STATE_OVERRIDE="$state" "$GATES" "$state/absent.jsonl" > "$out" || fail "gates scorer failed on an absent log"
  [ "$(wc -l < "$out" | tr -d ' ')" = 11 ] || fail "an absent log prints only the empty tables, including evidence sufficiency: $(cat "$out")"
  pass "the gates scorer scores only full-variant records with facts, joins ground truth from outcomes, backstop surfacing, and derivable main actions, splits wrong fires into delay and loss, and sweeps for the lowest clean floor"
}

test_gates_scorer_sufficiency_mode_judges_evidence_against_the_caller_bound() {
  local dir state out n rc prefix_len
  local base_t=1700000000

  mk_rec() {  # <state> <task> <wakeKey> <wake-text> <noul-or-"-"> <t-offset>
    local st=$1 task=$2 wk=$3 waketext=$4 noul=$5 off=$6 t sev answers facts
    sev='["False alarm or no functional impact","Routine recoverable interruption or non-blocking failure","Task blocked or failed after normal recovery","Security, privacy, data-loss, irreversible, credential, or external-publication impact"]'
    t=$(date -u -d "@$((base_t + off))" +%Y-%m-%dT%H:%M:%SZ)
    if [ "$noul" != "-" ]; then
      answers='{"no_new_outcome":{"type":"noul","noul":'$noul'}}'
      facts='{"wake_key":"'"$wk"'","new_status_bytes":{"'"$task"'":0},"pane":"fm-'"$task"'","authoritative_pr":{"present":false},"severity_classes":'$sev'}'
    else
      answers='{"stale_state":{"type":"choice","choice":"active","confidence":0.9}}'
      facts='{"wake_key":"'"$wk"'","new_status_bytes":{"'"$task"'":0},"pane":"fm-'"$task"'","authoritative_pr":{"present":false},"severity_classes":'$sev',"stale_series":{"series_index":2},"pane_observation":{"progressing":true,"busy_source":"tmux","seconds_since_last_activity":5}}'
    fi
    printf '%s
' '{"t":"'"$t"'","kind":"shadow","wake":"'"$waketext"'","seqs":["1"],"wakeKey":"'"$wk"'","tasks":["'"$task"'"],"wakeNo":1,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{"choice_confidence_floor":0.85,"noul_grant_below":0.15,"noul_pass_above":0.85},"answers":'"$answers"',"facts":'"$facts"'}' >> "$st/branch-mod-shadow.jsonl"
    FM_STATE_OVERRIDE="$st" "$ROOT/bin/fm-branch-outcome.sh" append --task "$task" --verdict routine --summary 'signal noted' --wake-key "$wk" >/dev/null
  }

  # (a) 60 clean routine fires at noul 0.9 plus 30 captain-labeled wakes below
  # the fire floor: pass at bound 0.05 with min-positives 30, not yet at 31.
  dir=$(make_case gates-sufficiency-a)
  state="$dir/state"
  out="$dir/sufficiency.out"
  printf 'id=t1\nwindow=fm-t1\nbackend=tmux\n' > "$state/t1.meta"
  printf 'working: t1\n' > "$state/t1.status"
  for n in $(seq 1 60); do mk_rec "$state" t1 "1701:$n" 'signal: A' 0.9 "$n"; done
  for n in $(seq 61 90); do
    mk_rec "$state" t1 "1701:$n" 'signal: A' 0.5 "$n"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append --task t1 --verdict captain --summary 'escalated' --wake-key "1701:$n" >/dev/null
  done
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 30 > "$out"
  rc=$?
  [ "$rc" = 0 ] || fail "60 clean fires at a 0.05 bound with 30 positives must be sufficient: rc=$rc $(grep '^sufficiency: absorb' "$out")"
  grep -Fx 'sufficiency: absorb-no-new-outcome pass (fires 60, loss 0, upper 0.0487, positives 30)' "$out" \
    || fail "the pass verdict must carry the counted evidence: $(grep '^sufficiency: absorb' "$out")"
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 31 > "$out"
  [ "$?" = 1 ] || fail "min-positives 31 with only 30 positives must be not yet: $(grep '^sufficiency: absorb' "$out")"
  grep -Fx 'sufficiency: absorb-no-new-outcome not yet (fires 60, loss 0, upper 0.0487, positives 30)' "$out" \
    || fail "the not-yet verdict must name the shortfall: $(grep '^sufficiency: absorb' "$out")"

  # (b) 99 clean fires and one loss-class wrong fire (n=100, k=1) with 30
  # positives: the exact Clopper-Pearson upper bound 0.0466 passes at bound
  # 0.05 and is not yet at 0.04.
  dir=$(make_case gates-sufficiency-b)
  state="$dir/state"
  out="$dir/sufficiency.out"
  printf 'id=t1\nwindow=fm-t1\nbackend=tmux\n' > "$state/t1.meta"
  printf 'working: t1\n' > "$state/t1.status"
  for n in $(seq 1 99); do mk_rec "$state" t1 "1702:$n" 'signal: A' 0.9 "$n"; done
  for n in $(seq 101 129); do
    mk_rec "$state" t1 "1702:$n" 'signal: A' 0.5 "$n"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append --task t1 --verdict captain --summary 'escalated' --wake-key "1702:$n" >/dev/null
  done
  mk_rec "$state" t1 '1702:100' 'signal: A' 0.9 200
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append --task t1 --verdict captain --summary 'escalated' --wake-key '1702:100' >/dev/null
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 30 > "$out"
  rc=$?
  [ "$rc" = 0 ] || fail "100 fires with 1 loss and a 0.0466 upper bound must pass at 0.05: $(grep '^sufficiency: absorb' "$out")"
  grep -Fx '| absorb-no-new-outcome | 100 | 1 | 0.0466 | 30 |' "$out" \
    || fail "the sufficiency row must carry the exact Clopper-Pearson bound: $(grep '^| absorb-no-new-outcome | 100' "$out")"
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient absorb-no-new-outcome --bound 0.04 --min-positives 30 > "$out"
  [ "$?" = 1 ] || fail "a 0.0466 upper bound must be not yet at bound 0.04: $(grep '^sufficiency: absorb' "$out")"

  # (c) usage errors exit 2 without touching the logs.
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient no-such-gate --bound 0.05 > "$out" 2>&1
  [ "$?" = 2 ] || fail "an unknown gate must be a usage error: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient absorb-no-new-outcome > "$out" 2>&1
  [ "$?" = 2 ] || fail "--sufficient without --bound must be a usage error: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient absorb-no-new-outcome --bound 1.5 > "$out" 2>&1
  [ "$?" = 2 ] || fail "a bound outside (0,1] must be a usage error: $(cat "$out")"
  mkdir "$state/unreadable.jsonl"
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient absorb-no-new-outcome --bound 0.05 "$state/unreadable.jsonl" > "$out" 2>&1
  [ "$?" = 2 ] || fail "a log that exists but cannot be read must be a read error, not not-yet: $(tail -2 "$out")"
  FM_STATE_OVERRIDE="$state" "$GATES" "$state/unreadable.jsonl" > "$out" 2>&1 \
    || fail "the ordinary mode keeps its exit-0 contract on an unreadable log: $(tail -2 "$out")"

  # (d) the truth sidecar: fires scored while the task records were live stay
  # readable from the snapshot after the records are gone, the snapshot is
  # never rewritten with an absent read, and a wake with no snapshot stays
  # out of the sufficiency counts.
  dir=$(make_case gates-sufficiency-sidecar)
  state="$dir/state"
  out="$dir/sufficiency.out"
  printf 'id=t9\nwindow=fm-t9\nbackend=tmux\n' > "$state/t9.meta"
  printf 'working: t9\n' > "$state/t9.status"
  printf 'id=t10\nwindow=fm-t10\nbackend=tmux\n' > "$state/t10.meta"
  printf 'working: t10\n' > "$state/t10.status"
  for n in 1 2; do mk_rec "$state" t9 "1703:$n" 'stale: fm-t9 (idle 900s, possible wedge, escalation 2)' - "$n"; done
  mk_rec "$state" t10 '1703:9' 'stale: fm-t10 (idle 900s, possible wedge, escalation 2)' - 9
  rm -f "$state/t10.meta" "$state/t10.status"

  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient stale-active-suppress --bound 0.05 --min-positives 0 > "$out"
  [ "$?" = 1 ] || fail "two fires with a 0.7764 upper bound cannot pass at 0.05: $(grep '^sufficiency: stale' "$out")"
  grep -Fx '| stale-active-suppress | 2 | 0 | 0.7764 | 0 |' "$out" \
    || fail "only the two snapshotted fires may count; the pre-torn wake stays out: $(grep '^| stale-active-suppress | ' "$out")"
  [ "$(wc -l < "$state/.branch-shadow-truth.jsonl" | tr -d ' ')" = 2 ] \
    || fail "only the wakes with live task records may be snapshotted: $(cat "$state/.branch-shadow-truth.jsonl")"

  rm -f "$state/t9.meta" "$state/t9.status"
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient stale-active-suppress --bound 0.05 --min-positives 0 > "$out"
  [ "$?" = 1 ] || fail "the sidecar must keep the counts stable after the task records are gone: $(grep '^sufficiency: stale' "$out")"
  grep -Fx '| stale-active-suppress | 2 | 0 | 0.7764 | 0 |' "$out" \
    || fail "the sufficiency counts must survive the teardown through the sidecar: $(grep '^| stale-active-suppress | ' "$out")"
  [ "$(wc -l < "$state/.branch-shadow-truth.jsonl" | tr -d ' ')" = 2 ] \
    || fail "the sidecar must never be rewritten with an absent read: $(cat "$state/.branch-shadow-truth.jsonl")"
  grep -F 'torn down (a task record is gone' "$out" >/dev/null \
    || fail "the unreadable pre-torn wake must still be noted: $(grep -i torn "$out")"

  # (f) live records stay the truth while present: a fire scored before the
  # merge poll is armed reads delay, reads correct once the poll is armed
  # (the sidecar's last line for the wake follows), and keeps reading
  # correct after the task records are gone.
  dir=$(make_case gates-sufficiency-live)
  state="$dir/state"
  out="$dir/live.out"
  printf 'id=t11\nwindow=fm-t11\nbackend=tmux\n' > "$state/t11.meta"
  printf 'working: t11\n' > "$state/t11.status"
  printf '%s\n' '{"t":"2023-11-14T22:13:21Z","kind":"shadow","wake":"working: t11","seqs":["1"],"wakeKey":"1704:1","tasks":["t11"],"wakeNo":1,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{"choice_confidence_floor":0.85,"noul_grant_below":0.15,"noul_pass_above":0.85},"answers":{"phase":{"type":"choice","choice":"finished_ready","confidence":0.92}},"facts":{"wake_key":"1704:1","new_status_bytes":{"t11":10},"pane":"fm-t11","authoritative_pr":{"present":true,"pr":"ow/repo#11"},"severity_classes":["a","b","c","d"]}}' >> "$state/branch-mod-shadow.jsonl"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append --task t11 --verdict routine --summary 'ready noted' --wake-key 1704:1 >/dev/null
  FM_STATE_OVERRIDE="$state" "$GATES" -v > "$out" || fail "live scorer failed"
  grep -F $'1704:1\tpr-ready-arm\tdelay' "$out" >/dev/null \
    || fail "before the poll is armed the fire must read delay: $(grep pr-ready-arm "$out")"
  : > "$state/t11.pr-poll"
  FM_STATE_OVERRIDE="$state" "$GATES" -v > "$out" || fail "live scorer failed after arming"
  grep -F $'1704:1\tpr-ready-arm\tcorrect' "$out" >/dev/null \
    || fail "once the poll is armed the live read must win over the earlier snapshot: $(grep pr-ready-arm "$out")"
  [ "$(jq -r 'select(.wakeKey == "1704:1") | .pr_truth' "$state/.branch-shadow-truth.jsonl" | tail -1)" = 1 ] \
    || fail "the sidecar's last line for the wake must carry the armed read: $(cat "$state/.branch-shadow-truth.jsonl")"
  [ "$(wc -l < "$state/.branch-shadow-truth.jsonl" | tr -d ' ')" = 2 ] \
    || fail "a line is appended only when the live bits change: $(cat "$state/.branch-shadow-truth.jsonl")"
  rm -f "$state/t11.pr-poll" "$state/t11.busy-state"
  FM_STATE_OVERRIDE="$state" "$GATES" -v > "$out" || fail "live scorer failed in the teardown window"
  grep -F $'1704:1\tpr-ready-arm\tcorrect' "$out" >/dev/null \
    || fail "a retired poll while the meta is present must not flip the recorded truth: $(grep pr-ready-arm "$out")"
  [ "$(wc -l < "$state/.branch-shadow-truth.jsonl" | tr -d ' ')" = 2 ] \
    || fail "a 1-to-0 live change must never be recorded: $(cat "$state/.branch-shadow-truth.jsonl")"
  rm -f "$state/t11.meta" "$state/t11.status"
  FM_STATE_OVERRIDE="$state" "$GATES" -v > "$out" || fail "live scorer failed after teardown"
  grep -F $'1704:1\tpr-ready-arm\tcorrect' "$out" >/dev/null \
    || fail "after teardown the sidecar must still read correct: $(grep pr-ready-arm "$out")"
  [ "$(wc -l < "$state/.branch-shadow-truth.jsonl" | tr -d ' ')" = 2 ] \
    || fail "the sidecar must never be written from an absent read: $(cat "$state/.branch-shadow-truth.jsonl")"

  # (i) a retired status log while the meta is present is not live: the
  # backstop bit is never snapshotted from the absent scan, so a wake with
  # no earlier snapshot stays unreadable instead of reading a false 0.
  dir=$(make_case gates-sufficiency-status-retired)
  state="$dir/state"
  out="$dir/status.out"
  printf 'id=t14\nwindow=fm-t14\nbackend=tmux\n' > "$state/t14.meta"
  printf 'working: t14\n' > "$state/t14.status"
  mk_rec "$state" t14 1706:1 'signal: t14' 0.9 1
  printf 'done: t14 finished\n' >> "$state/t14.status"
  mk_rec "$state" t14 1706:2 'signal: t14' 0.9 2
  rm -f "$state/t14.status"
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 0 > "$out"
  [ "$?" = 1 ] || fail "unreadable fires cannot pass: $(grep '^sufficiency: absorb' "$out")"
  grep -Fx '| absorb-no-new-outcome | 0 | 0 | - | 0 |' "$out" \
    || fail "a wake whose status log is retired must stay out of the counts, never read as a clean fire: $(grep '^| absorb-no-new-outcome | ' "$out")"
  [ ! -e "$state/.branch-shadow-truth.jsonl" ] \
    || fail "the sidecar must never be written from an absent status log: $(cat "$state/.branch-shadow-truth.jsonl")"

  # (g) candidate-order counts an absorb-all decision as evidence: zero
  # fires plus one absorb-all loss reads fires 1, loss 1.
  dir=$(make_case gates-sufficiency-cand)
  state="$dir/state"
  out="$dir/cand.out"
  printf 'id=t12\nwindow=fm-t12\nbackend=tmux\n' > "$state/t12.meta"
  printf 'id=t13\nwindow=fm-t13\nbackend=tmux\n' > "$state/t13.meta"
  printf 'working: t12\n' > "$state/t12.status"
  printf 'working: t13\n' > "$state/t13.status"
  printf '%s\n' '{"t":"2023-11-14T22:13:22Z","kind":"shadow","wake":"signal: compound","seqs":["1"],"wakeKey":"1705:1","tasks":["t12","t13"],"wakeNo":1,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{"choice_confidence_floor":0.85,"noul_grant_below":0.15,"noul_pass_above":0.85},"answers":{"candidates":{"t12":{"type":"noul","noul":0.5},"t13":{"type":"noul","noul":0.4}}},"facts":{"wake_key":"1705:1","new_status_bytes":{"t12":0,"t13":0},"pane":"fm-t12","authoritative_pr":{"present":false},"severity_classes":["a","b","c","d"],"candidates":{"t12":0.5,"t13":0.4}}}' >> "$state/branch-mod-shadow.jsonl"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append --task t13 --verdict captain --summary 'escalated' --wake-key 1705:1 >/dev/null
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append --task t12 --verdict routine --summary 'noted' --wake-key 1705:1 >/dev/null
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient candidate-order --bound 0.05 --min-positives 0 > "$out"
  [ "$?" = 1 ] || fail "one absorb-all loss cannot pass: $(grep '^sufficiency: candidate' "$out")"
  grep -F '| candidate-order | 1 | 0 | 0 |' "$out" >/dev/null \
    || fail "the ordinary table must show the gate silent: $(grep '^| candidate-order' "$out")"
  grep -F 'sufficiency: candidate-order not yet (fires 1, loss 1,' "$out" >/dev/null \
    || fail "an absorb-all loss must count as a decision and a loss: $(grep '^sufficiency: candidate' "$out")"

  # (h) an absent log in sufficiency mode is not yet, never sufficient.
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient candidate-order --bound 0.05 --min-positives 0 "$state/absent.jsonl" > "$out"
  [ "$?" = 1 ] || fail "an absent log must be not yet: $(tail -2 "$out")"
  grep -Fx 'sufficiency: candidate-order not yet (fires 0, loss 0, upper -, positives 0)' "$out" >/dev/null \
    || fail "an absent log prints the empty verdict: $(grep '^sufficiency' "$out")"

  # (e) ordinary and sufficiency runs share a byte-identical prefix: the
  # sufficiency mode only appends its verdict lines to the ordinary output.
  FM_STATE_OVERRIDE="$state" "$GATES" > "$dir/ordinary.out"
  FM_STATE_OVERRIDE="$state" "$GATES" --sufficient stale-active-suppress --bound 0.05 --min-positives 0 > "$out"
  prefix_len=$(wc -l < "$dir/ordinary.out" | tr -d ' ')
  [ "$prefix_len" -gt 0 ] || fail "the ordinary run must print its tables: $(cat "$dir/ordinary.out")"
  head -n "$prefix_len" "$out" | cmp -s - "$dir/ordinary.out" \
    || fail "the sufficiency mode must not change the ordinary output: $(diff "$dir/ordinary.out" <(head -n "$prefix_len" "$out") | head)"
  [ "$(wc -l < "$out" | tr -d ' ')" -gt "$prefix_len" ] \
    || fail "the sufficiency run must append its verdict lines: $(tail -3 "$out")"

  pass "the gates scorer sufficiency mode counts readable-truth fires against the caller's bound, sidecars the decaying truth at scoring time, never rewrites an absent read, and keeps the ordinary output byte-stable"
}

test_evidence_bundle_marks_new_lines_and_advances_the_offset() {
  local dir state out
  dir=$(make_case evidence)
  state="$dir/state"
  out="$dir/evidence.out"
  printf 'working: started\ndone: PR https://example.test/1 checks green\n' > "$state/t1.status"

  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "evidence bundle failed: $(cat "$out")"
  head -n 1 "$out" | grep -qx '## task t1 status bytes 0-62' \
    || fail "first bundle did not name the whole log as its byte range: $(head -n 1 "$out")"
  grep -q '^  done: PR https://example.test/1 checks green$' "$out" \
    || fail "the done line was not presented as NEW: $(cat "$out")"
  [ "$(cat "$state/.t1.classifier-offset")" = 62 ] \
    || fail "the offset file was not advanced to the log size: $(cat "$state/.t1.classifier-offset")"

  printf 'working: follow-up\n' >> "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "second evidence bundle failed"
  head -n 1 "$out" | grep -qx '## task t1 status bytes 62-81' \
    || fail "second bundle did not start at the previous offset: $(head -n 1 "$out")"
  grep -q '^  working: follow-up$' "$out" || fail "the appended line was not presented as NEW"
  awk '/HISTORY/ { h=1; next } h && /done: PR/ { found=1 } END { exit found ? 0 : 1 }' "$out" \
    || fail "the earlier done line was not presented as HISTORY: $(cat "$out")"

  : > "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "evidence bundle after a log reset failed"
  head -n 1 "$out" | grep -qx '## task t1 status bytes 0-0' \
    || fail "a shrunken log did not reset the offset: $(head -n 1 "$out")"

  FM_STATE_OVERRIDE="$state" "$EVIDENCE" 'bad task' > "$out" 2>&1 && fail "an invalid task id was accepted"

  printf 'working: well under the cap\n' >> "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "the uncapped evidence bundle failed"
  grep -q '^## the NEW block above stops at the 6000-byte cap' "$out" \
    && fail "an uncapped bundle claimed the NEW block was truncated"
  for i in $(seq 1 100); do printf 'working: %084d\n' "$i" >> "$state/t1.status"; done
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "the capped evidence bundle failed"
  grep -qF '## the NEW block above stops at the 6000-byte cap - status lines past the cut are not in this bundle' "$out" \
    || fail "a NEW block over the 6000-byte cap was not marked truncated: $(head -c 400 "$out")"
  awk 'index($0, "## the NEW block above stops") { seen=1; next } seen && /^## earlier lines/ { ok=1 } END { exit ok ? 0 : 1 }' "$out" \
    || fail "the truncation marker was not emitted directly before the HISTORY marker"

  FM_STATE_OVERRIDE="$state" "$EVIDENCE" t1 > "$out" || fail "the post-cap evidence bundle failed"
  grep -q '^## the NEW block above stops at the 6000-byte cap' "$out" \
    && fail "a bundle with no new bytes still claimed the NEW block was truncated"
  pass "the evidence bundle presents NEW and HISTORY lines by byte offset, marks a NEW block cut at the 6000-byte cap, and owns the per-task offset file"
}

test_routine_covered_lines_surface_only_under_the_mod() {
  local dir state out body old
  dir=$(make_case routine-covered)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: PR https://example.test/2 checks green\n' > "$state/t2.status"
  set_mtime "$old" "$state/t2.status"
  append_outcome "$state" t2 routine 'branch judged the completion routine'

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed without the mod"
  if grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null; then
    fail "a routine-covered line surfaced in a home without the mod: $(cat "$out")"
  fi
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" --routine-covered t2 > "$out" || fail "routine-covered listing failed"
  grep -q "$(printf '^45\tdone: PR https://example.test/2 checks green$')" "$out" \
    || fail "the routine-covered listing did not name the covered line and its end offset: $(cat "$out")"

  : > "$state/.branch-mod-mode"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed under the mod"
  grep -F 'STATUS OUTCOME BACKSTOP (captain-facing task event with no covering branch outcome, or covered only by a ROUTINE one):' "$out" >/dev/null \
    || fail "the routine-covered backstop did not surface under the mod: $(cat "$out")"
  body=$(backstop_body "$out")
  case "$body" in *'t2 done: PR https://example.test/2 checks green (covered by a ROUTINE branch outcome)'*) ;; *) fail "the covered line was not presented with its provenance: $body" ;; esac

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second main drain failed under the mod"
  if grep -F 'covered by a ROUTINE branch outcome' "$out" >/dev/null; then
    fail "a routine-covered line was re-presented on the next drain: $(cat "$out")"
  fi

  printf 'working: rebased\n' > "$state/t3.status"
  set_mtime "$old" "$state/t3.status"
  append_outcome "$state" t3 routine 'progress only'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed for a routine-only task"
  if grep -F 't3 ' "$out" >/dev/null; then
    fail "a routine status line covered by a routine outcome was presented: $(cat "$out")"
  fi

  printf 'done: PR https://example.test/4 checks green\n' > "$state/t4.status"
  set_mtime "$old" "$state/t4.status"
  append_outcome "$state" t4 captain 'completion reached main'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed for a captain-covered task"
  if grep -F 't4 ' "$out" >/dev/null; then
    fail "a line covered by a CAPTAIN outcome was re-presented under the mod: $(cat "$out")"
  fi

  printf 'done: PR https://example.test/8 checks green\nworking: cleanup\n' > "$state/t8.status"
  set_mtime "$old" "$state/t8.status"
  append_outcome "$state" t8 routine 'branch judged both lines routine'
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed when the newest covered line is routine"
  body=$(backstop_body "$out")
  case "$body" in *'t8 done: PR https://example.test/8 checks green (covered by a ROUTINE branch outcome)'*) ;; *) fail "a covered done line behind a newer routine line was not presented: $(cat "$out")" ;; esac
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second main drain failed for the routine-newest task"
  if grep -F 't8 ' "$out" >/dev/null; then
    fail "the covered done line behind a newer routine line was re-presented: $(cat "$out")"
  fi

  printf 'needs-decision: [key=pick-1] merge now or wait\n' > "$state/t9.status"
  set_mtime "$old" "$state/t9.status"
  append_outcome "$state" t9 routine 'branch judged the decision routine'
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" --routine-covered t9 > "$out" || fail "routine-covered listing failed for a keyed decision"
  [ ! -s "$out" ] || fail "a keyed needs-decision line was listed as routine-covered instead of left to the OPEN DECISIONS fold: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed for a keyed decision covered by a routine outcome"
  if grep -F 'covered by a ROUTINE branch outcome' "$out" >/dev/null; then
    fail "a keyed needs-decision line was re-presented outside the fold: $(cat "$out")"
  fi
  grep -F 'pick-1' "$out" >/dev/null || fail "the keyed decision did not reach the OPEN DECISIONS fold: $(cat "$out")"
  pass "a captain-facing line covered only by a ROUTINE branch outcome surfaces once on the main drain, only under the mod, even behind a newer routine line, and keyed decisions stay in the fold"
}

test_routine_covered_lines_are_byte_exact_across_outcomes() {
  local dir state out old
  dir=$(make_case routine-covered-offsets)
  state="$dir/state"
  out="$dir/covered.out"
  old=$(( $(date +%s) - 20 ))
  : > "$state/.branch-mod-mode"

  printf 'done: first completion\n' > "$state/t5.status"
  set_mtime "$old" "$state/t5.status"
  append_outcome "$state" t5 captain 'first completion reached main'
  printf 'failed: second attempt failed\n' >> "$state/t5.status"
  append_outcome "$state" t5 routine 'branch judged the failure routine'

  FM_STATE_OVERRIDE="$state" "$EVIDENCE" --routine-covered t5 > "$out" || fail "routine-covered listing failed"
  [ "$(wc -l < "$out" | tr -d ' ')" = 1 ] || fail "expected exactly the one line the routine outcome covered, got: $(cat "$out")"
  grep -q "$(printf '\tfailed: second attempt failed$')" "$out" \
    || fail "the line under the routine outcome was not listed: $(cat "$out")"
  pass "only the lines between the previous outcome's endpoint and the routine outcome's endpoint are listed"
}

test_routine_covered_lines_omitted_by_the_byte_cap_are_presented_on_the_next_drain() {
  local dir state out body old i long
  dir=$(make_case routine-covered-cap)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))
  : > "$state/.branch-mod-mode"
  long=$(printf 'x%.0s' $(seq 1 180))
  : > "$state/t10.status"
  i=1
  while [ "$i" -le 19 ]; do
    printf 'done: completion %02d %s\n' "$i" "$long" >> "$state/t10.status"
    i=$((i + 1))
  done
  printf 'done: short tail\n' >> "$state/t10.status"
  set_mtime "$old" "$state/t10.status"
  append_outcome "$state" t10 routine 'branch judged every completion routine'
  printf 'done: uncovered tail\n' >> "$state/t10.status"
  set_mtime "$old" "$state/t10.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed under the byte cap"
  body=$(backstop_body "$out")
  case "$body" in *'done: completion 18 '*) ;; *) fail "the covered lines under the cap were not presented: $(cat "$out")" ;; esac
  case "$body" in *'done: completion 19 '*) fail "a line past the byte cap was presented: $body" ;; esac
  case "$body" in *'done: short tail'*) fail "a later short line was presented ahead of an omitted one, which would acknowledge past it: $body" ;; esac
  case "$body" in *'done: uncovered tail'*) fail "the uncovered newest line was presented ahead of an omitted covered one, which would acknowledge past it: $body" ;; esac
  grep -q '^STATUS OUTCOME BACKSTOP: 3 more omitted (byte cap)$' "$out" || fail "the omitted lines were not counted: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second main drain failed under the byte cap"
  body=$(backstop_body "$out")
  case "$body" in *'done: completion 19 '*) ;; *) fail "the line omitted by the byte cap was never presented: $(cat "$out")" ;; esac
  case "$body" in *'done: short tail'*) ;; *) fail "the short line after the omitted one was never presented: $(cat "$out")" ;; esac
  case "$body" in *'t10 done: uncovered tail'*) ;; *) fail "the uncovered newest line was never presented: $(cat "$out")" ;; esac
  case "$body" in *'done: completion 18 '*) fail "an already presented line was re-presented: $body" ;; esac
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "third main drain failed under the byte cap"
  if grep -F 't10 ' "$out" >/dev/null; then
    fail "a presented line was re-presented on the third drain: $(cat "$out")"
  fi
  pass "a routine-covered line omitted by the byte cap is presented on the next drain, and neither a later covered line nor the uncovered newest line acknowledges past it"
}

test_scorer_labels_records_from_the_status_bytes_they_judged() {
  local dir state out
  dir=$(make_case scorer)
  state="$dir/state"
  out="$dir/score.out"
  printf 'working: a\ndone: PR https://example.test/6 checks green\n' > "$state/t6.status"
  printf 'working: b\n' > "$state/t7.status"
  {
    printf '{"t":"x","verdict":"routine","model":"haiku","evidence":[{"task":"t6","from":0,"to":56}]}\n'
    printf '{"t":"x","verdict":"captain","model":"haiku","evidence":[{"task":"t6","from":0,"to":56}]}\n'
    printf 'not json\n'
    printf '{"t":"x","verdict":"routine","model":"haiku","evidence":[{"task":"t7","from":0,"to":11}]}\n'
    printf '{"t":"x","verdict":"uncertain","model":"haiku","evidence":[{"task":"t7","from":0,"to":11}]}\n'
    printf '{"t":"x","verdict":"routine","model":"sonnet","evidence":[{"task":"gone","from":0,"to":11}]}\n'
  } > "$state/branch-mod-classifications.jsonl"

  FM_STATE_OVERRIDE="$state" "$SCORE" -v > "$out" || fail "scorer failed: $(cat "$out")"
  grep -q '^| haiku | 4 | 2 / 1 / 1 | 1 | 1 | 1 | 1 | 0 |$' "$out" \
    || fail "haiku row is wrong: $(cat "$out")"
  grep -q '^| sonnet | 1 | 1 / 0 / 0 | 0 | 0 | 0 | 0 | 1 |$' "$out" \
    || fail "sonnet row did not count the torn-down task as unscorable: $(cat "$out")"
  grep -q '^- record 1 (haiku): label captain, verdict routine CAPTAIN MISS: t6,0,56$' "$out" \
    || fail "the false-routine record was not listed as a captain miss: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$SCORE" "$state/absent.jsonl" > "$out" || fail "scorer failed on an absent log"
  [ "$(wc -l < "$out" | tr -d ' ')" = 2 ] || fail "an absent log must print only the table header: $(cat "$out")"
  pass "the scorer labels each record from the status bytes it judged, reports false-routine verdicts as captain misses, and skips a torn line without losing the records after it"
}

test_scorer_prefers_a_captured_evidence_copy_and_falls_back_to_byte_ranges() {
  local dir state out to_routine to_done to_big
  dir=$(make_case scorer-captured)
  state="$dir/state"
  out="$dir/score.out"

  # The live task t9 exercises the byte-range fallback; the three gone-*
  # tasks keep their status lines only inside captured copies, exactly as
  # records look after teardown deletes the log the ranges point at.
  printf 'working: a\ndone: PR https://example.test/7 checks green\n' > "$state/t9.status"
  printf 'working: h\ndone: PR https://example.test/8 checks green\n' > "$state/gone-done.status"
  printf 'working: h\n' > "$state/gone-routine.status"
  # gone-big carries its captain line beyond the 6,000-byte NEW block the
  # gatherer emits, so its captured copy judges only routine lines while its
  # recorded range still resolves to captain: labelling the copy and not the
  # range is what proves the copy is preferred when both exist.
  {
    printf 'working: h\n'
    for i in $(seq 1 70); do printf 'working: %084d\n' "$i"; done
    printf 'done: PR https://example.test/10 checks green\n'
  } > "$state/gone-big.status"

  to_done=$(wc -c < "$state/gone-done.status")
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" gone-done > "$dir/bundle-done"
  to_routine=$(wc -c < "$state/gone-routine.status")
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" gone-routine > "$dir/bundle-routine"
  to_big=$(wc -c < "$state/gone-big.status")
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" gone-big > "$dir/bundle-big"
  to_t9=$(wc -c < "$state/t9.status")
  # no-log has never had a status log, so the gatherer emits header and state
  # only - a real bundle with neither section marker.
  FM_STATE_OVERRIDE="$state" "$EVIDENCE" no-log > "$dir/bundle-no-log"
  {
    printf '## task trunc status bytes 0-400\n'
    printf '## status lines appended since the last classified wake (NEW - judge these)\n'
    printf '  working: still building\n'
    printf '  done: PR https://example.test/11 checks green\n'
  } > "$dir/copy-no-history"
  # The gatherer's 6,000-byte NEW cap can end the block mid-line, and sed
  # leaves that partial line without a trailing newline, so the HISTORY
  # marker fuses onto it exactly as written here.
  {
    printf '## task fused-new status bytes 0-500\n'
    printf '## status lines appended since the last classified wake (NEW - judge these)\n'
    printf '  working: still building\n'
    printf '  done: PR http## earlier lines, already handled by earlier wakes (HISTORY - never escalate these)\n'
    printf '  working: an earlier line\n'
  } > "$dir/copy-fused-new"
  {
    printf '## task fused-history status bytes 0-500\n'
    printf '## status lines appended since the last classified wake (NEW - judge these)\n'
    printf '  working: still building\n'
    printf '  working: partial li## earlier lines, already handled by earlier wakes (HISTORY - never escalate these)\n'
    printf '  done: PR https://example.test/12 checks green\n'
  } > "$dir/copy-fused-history"
  rm -f "$state/gone-routine.status" "$state/.gone-routine.classifier-offset" \
    "$state/gone-done.status" "$state/.gone-done.classifier-offset" \
    "$state/gone-big.status" "$state/.gone-big.classifier-offset"

  cap_record() {  # <verdict> <model> <task> <to> <bundle-file>: one captured-copy record
    jq -nc --arg verdict "$1" --arg model "$2" --arg task "$3" --argjson to "$4" --rawfile text "$5" \
      '{t: "x", verdict: $verdict, model: $model,
        evidence: [{task: $task, from: 0, to: $to, text: $text, text_len: ($text | length)}],
        text_cap: 8192}'
  }
  {
    printf '{"t":"x","verdict":"routine","model":"haiku","evidence":[{"task":"t9","from":0,"to":%s}]}\n' "$to_t9"
    cap_record routine haiku gone-done "$to_done" "$dir/bundle-done"
    cap_record routine haiku gone-big "$to_big" "$dir/bundle-big"
    cap_record captain haiku gone-routine "$to_routine" "$dir/bundle-routine"
    jq -nc '{t: "x", verdict: "uncertain", model: "haiku",
            evidence: [{task: "gone-fail", from: -1, to: -1,
                        text: "## task gone-fail\n(evidence gatherer failed: boom)\n", text_len: 0}]
            , text_cap: 8192}
            | .evidence[0].text_len = (.evidence[0].text | length)'
    printf '{"t":"x","verdict":"uncertain","model":"sonnet","evidence":[{"task":"vanished","from":0,"to":11}]}\n'
    # A copy of a task with no status log at all carries neither section
    # marker, and a copy whose HISTORY marker was lost to truncation carries
    # only the NEW one: neither delimits the lines the classifier was shown,
    # so both must land in the unscorable column rather than be labelled.
    cap_record routine opus no-log 0 "$dir/bundle-no-log"
    jq -nc --arg task trunc --rawfile text "$dir/copy-no-history" \
      '{t: "x", verdict: "routine", model: "opus",
        evidence: [{task: $task, from: 0, to: 400, text: $text, text_len: ($text | length)}],
        text_cap: 8192}'
    # A fused marker still delimits the section: the partial NEW line fused
    # ahead of it is judged, the already-handled lines after it are not.
    jq -nc --arg task fused-new --rawfile text "$dir/copy-fused-new" \
      '{t: "x", verdict: "routine", model: "opus",
        evidence: [{task: $task, from: 0, to: 500, text: $text, text_len: ($text | length)}],
        text_cap: 8192}'
    jq -nc --arg task fused-history --rawfile text "$dir/copy-fused-history" \
      '{t: "x", verdict: "routine", model: "opus",
        evidence: [{task: $task, from: 0, to: 500, text: $text, text_len: ($text | length)}],
        text_cap: 8192}'
  } > "$state/branch-mod-classifications.jsonl"

  FM_STATE_OVERRIDE="$state" "$SCORE" -v > "$out" || fail "scorer failed: $(cat "$out")"
  grep -q '^| haiku | 5 | 3 / 1 / 1 | 2 | 0 | 1 | 1 | 1 |$' "$out" \
    || fail "haiku row did not score the captured and fallback records together: $(cat "$out")"
  grep -q '^| sonnet | 1 | 0 / 0 / 1 | 0 | 0 | 0 | 0 | 1 |$' "$out" \
    || fail "sonnet row did not keep a range-only dead record unscorable: $(cat "$out")"
  grep -qF "record 1 (haiku): label captain, verdict routine CAPTAIN MISS: t9,0,${to_t9}" "$out" \
    || fail "the fallback record was not labelled from its byte range: $(cat "$out")"
  grep -qF "record 2 (haiku): label captain, verdict routine CAPTAIN MISS: gone-done,0,${to_done}+captured" "$out" \
    || fail "the torn-down task's captured copy did not label the captain miss: $(cat "$out")"
  grep -qF "label routine, verdict captain: gone-routine,0,${to_routine}+captured" "$out" \
    || fail "the routine-only captured copy did not override the captain verdict: $(cat "$out")"
  if grep -qF 'gone-big' "$out"; then
    fail "the beyond-the-NEW-cap copy wrongly agreed with its captain range: $(cat "$out")"
  fi

  grep -q '^| opus | 4 | 4 / 0 / 0 | 1 | 0 | 0 | 1 | 2 |$' "$out" \
    || fail "a captured copy missing a section marker was scored instead of counted unscorable, or a fused-marker copy was mislabelled: $(cat "$out")"
  grep -qF 'record 9 (opus): label captain, verdict routine CAPTAIN MISS: fused-new,0,500+captured' "$out" \
    || fail "the NEW line fused ahead of the HISTORY marker was dropped instead of judged: $(cat "$out")"
  if grep -qF 'fused-history,0,500' "$out"; then
    fail "the fused HISTORY marker let an already-handled line label the record: $(cat "$out")"
  fi
  if grep -qF 'trunc,0,400' "$out"; then
    fail "the copy with no HISTORY marker fabricated a label from already-handled lines: $(cat "$out")"
  fi
  if grep -qF 'no-log,0,0' "$out"; then
    fail "the copy of a task with no status log was labelled instead of counted unscorable: $(cat "$out")"
  fi

  FM_STATE_OVERRIDE="$state" "$SCORE" --help > "$out" || fail "scorer help failed"
  grep -q 'captured evidence copy' "$out" || fail "scorer help lost the captured-copy contract: $(cat "$out")"
  grep -q 'section markers' "$out" || fail "scorer help lost the missing-marker rule: $(cat "$out")"
  pass "the scorer labels captured copies in place of deleted status logs, still labels range-only records from live bytes, and marks which evidence decided"
}

test_shadow_jev_helper_keeps_the_key_off_argv_and_the_child_env() {
  local dir home fakebin out code body
  dir=$(make_case jev-helper)
  home="$dir/home"
  fakebin="$dir/fakebin"
  mkdir -p "$home" "$fakebin"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: record argv and the fd-3 header, record whether the key leaked
# into the child environment, honor -o <file> for the response body, and print
# the -w format with %{http_code} expanded to FAKE_JEV_HTTP (default 200).
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ]; then
  printf 'key-in-child-env\n' >> "${FAKE_JEV_LOG:?}/leak"
fi
printf '%s\n' "$@" >> "${FAKE_JEV_LOG:?}/argv"
_out=""
_wfmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) _out=$2; shift 2 ;;
    -w) _wfmt=$2; shift 2 ;;
    -H) case "$2" in
          @/dev/fd/3) cat <&3 > "${FAKE_JEV_LOG:?}/header" ;;
          *) printf '%s\n' "$2" > "${FAKE_JEV_LOG:?}/header" ;;
        esac
        shift 2 ;;
    *) shift ;;
  esac
done
cat > "${FAKE_JEV_LOG:?}/body"
[ "${FAKE_JEV_HTTP:-200}" = 200 ] && cat "${FAKE_JEV_RESPONSE:?}" > "${_out:?}"
printf '%s\n' "${_wfmt//%\{http_code\}/${FAKE_JEV_HTTP:-200}}"
SH
  chmod +x "$fakebin/curl"
  export FAKE_JEV_LOG="$dir/log"
  mkdir -p "$FAKE_JEV_LOG"
  printf '%s\n' '{"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"main","confidence":0.91}}}' > "$dir/response.json"
  export FAKE_JEV_RESPONSE="$dir/response.json"

  # Absent key: one unavailable JSON line, exit 0, no curl call.
  out=$(FM_HOME="$home" "$JEV" <<< '{"model":"jev-latest","state":{},"questions":{}}')
  code=$?
  [ "$code" = 0 ] || fail "absent key must exit 0, got $code"
  printf '%s' "$out" | jq -e '.ok == false and .unavailable == "key absent"' >/dev/null     || fail "absent key must print an unavailable record: $out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "absent key must print exactly one line: $out"
  [ ! -f "$FAKE_JEV_LOG/argv" ] || fail "absent key must never call curl"
  pass "the jev helper is off without a key: one unavailable line, exit 0, no network"

  # Key from the home's .env: forwarded on the fd-3 header only, never on
  # argv, never in the child environment; the request body is forwarded whole.
  printf '%s\n' 'TYPESAFE_API_KEY=sk-jev-trial-key' > "$home/.env"
  body='{"model":"jev-latest","state":{"wake":"signal: x"},"questions":{"route":{}}}'
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$JEV" <<< "$body")
  code=$?
  [ "$code" = 0 ] || fail "happy path must exit 0, got $code"
  printf '%s' "$out" | jq -e '.ok == true and .model == "jev-1.13.0" and .answers.route.choice == "main"' >/dev/null     || fail "happy path must print one ok record with model and answers: $out"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "happy path must print exactly one line: $out"
  assert_equals 'Authorization: Bearer sk-jev-trial-key' "$(cat "$FAKE_JEV_LOG/header")" "the key rides the fd-3 Authorization header"
  if grep -q 'sk-jev-trial-key' "$FAKE_JEV_LOG/argv"; then
    fail "the key must never appear on curl argv"
  fi
  [ ! -f "$FAKE_JEV_LOG/leak" ] || fail "the key must be unset in the curl child environment"
  assert_equals "$body" "$(cat "$FAKE_JEV_LOG/body")" "the request body is forwarded whole on stdin"
  pass "the jev helper forwards the request and the key reaches curl only on the fd-3 header"

  # Non-200: one unavailable line naming the status, exit 0.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FAKE_JEV_HTTP=503 "$JEV" <<< '{"model":"jev-latest","state":{},"questions":{}}')
  code=$?
  [ "$code" = 0 ] || fail "http failure must exit 0, got $code"
  printf '%s' "$out" | jq -e '.ok == false and .unavailable == "http 503"' >/dev/null     || fail "http failure must record the status: $out"
  pass "an http failure becomes one unavailable record and never a nonzero exit"
}

test_shadow_pane_helper_reports_only_what_it_can_read() {
  local dir state out
  dir=$(make_case pane-helper)
  state="$dir/state"
  FM_STATE_OVERRIDE="$state" "$PANE" t1 > "$dir/off.out" 2>/dev/null && fail "pane helper must be inert without the mod switch"
  [ -s "$dir/off.out" ] && fail "an inert pane helper must print nothing: $(cat "$dir/off.out")"

  printf '%s\n' '.branch-mod-mode marker' > "$state/.branch-mod-mode"
  printf 'project=demo\n' > "$state/t1.meta"

  # No window in the meta: the pane endpoint is unknown, so the record is
  # unavailable rather than invented.
  out=$(FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" "$PANE" t1 2>/dev/null) || \
    fail "pane helper must exit 0 with an unknown endpoint"
  printf '%s' "$out" | jq -e '.unavailable != null and .task == "t1"' >/dev/null \
    || fail "an unknown endpoint must print unavailable: $out"

  # A readable capture plus the busy-state record and progress marker: only
  # fields with evidence appear.
  printf 'window=fm-t1\n' >> "$state/t1.meta"
  printf 'pane line one\npane line two\n' > "$dir/capture.txt"
  printf 'v1 gen=1 seq=2 state=busy source=pi-ext event=turn ts=1700000000\n' > "$state/t1.busy-state"
  printf 'x\n' > "$state/t1.progress"
  set_mtime $(( $(date +%s) - 120 )) "$state/t1.progress"
  out=$(FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/capture.txt" "$PANE" t1 2>/dev/null)
  printf '%s' "$out" | jq -e '
    .unavailable == null and .task == "t1"
    and .tail == "pane line one\npane line two"
    and .observation.progressing == true
    and .observation.busy_source == "pi-ext"
    and (.observation.seconds_since_last_activity | type == "number" and . >= 115 and . <= 600)
    and ((.observation | keys | sort) == ["busy_source", "progressing", "seconds_since_last_activity"])' >/dev/null     || fail "pane evidence must carry exactly the readable fields: $out"

  # An idle busy-state record flips progressing without inventing anything else.
  printf 'v1 gen=1 seq=3 state=idle source=pi-ext event=idle ts=1700000000\n' > "$state/t1.busy-state"
  rm -f "$state/t1.progress"
  out=$(FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/capture.txt" "$PANE" t1 2>/dev/null)
  printf '%s' "$out" | jq -e '.observation.progressing == false and .observation.seconds_since_last_activity == null' >/dev/null \
    || fail "an idle record must report progressing false and drop the absent activity field: $out"

  # Window identity and the watcher's stale-series markers: the key transform
  # mirrors the watcher's window_key(), so a target with ':' and '.' still
  # finds its markers, and window+stale evidence survives without a tail.
  printf 'id=t9\nwindow=fm:t9.v1\nbackend=tmux\n' > "$state/t9.meta"
  printf '3\n' > "$state/.count-fm_t9_v1"
  printf '1\n' > "$state/.wedge-escalations-fm_t9_v1"
  out=$(FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" "$PANE" t9 2>/dev/null)
  printf '%s' "$out" | jq -e '
    .unavailable == null and .task == "t9"
    and .window == "fm:t9.v1"
    and .stale.series_index == 3 and .stale.wedge_escalations == 1
    and .tail == null and .observation == null' >/dev/null \
    || fail "window and stale evidence must survive without a readable tail: $out"

  # Neither marker present: the stale field is omitted rather than invented.
  printf 'window=fm-t2\n' > "$state/t2.meta"
  out=$(FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/capture.txt" "$PANE" t2 2>/dev/null)
  printf '%s' "$out" | jq -e '.window == "fm-t2" and .stale == null' >/dev/null \
    || fail "an absent stale series must omit the field: $out"
  pass "the pane helper reports only readable evidence and omits every field it cannot read"
}

test_shadow_scorer_joins_records_to_outcomes_by_wake_identity() {
  local dir state out
  dir=$(make_case shadow-scorer)
  state="$dir/state"
  out="$dir/score.out"
  cat > "$state/branch-outcomes.jsonl" <<'EOF'
{"seq":1,"epoch":1,"task":"t1","wake":"agent text","verdict":"routine","summary":"x","silent":false,"statusEndpoint":0,"statusIdent":"-","wakeKey":"1700:1,1700:2"}
{"seq":2,"epoch":1,"task":"t1","wake":"agent text","verdict":"captain","summary":"y","silent":false,"statusEndpoint":0,"statusIdent":"-","wakeKey":"1700:1,1700:2"}
{"seq":3,"epoch":1,"task":"t1","wake":"agent text","verdi
{"seq":3,"epoch":1,"task":"t1","wake":"agent text","verdict":"routine","summary":"z","silent":false,"statusEndpoint":0,"statusIdent":"-","wakeKey":"1700:4"}
EOF
  {
    printf '%s\n' '{"t":"1","wake":"signal: A","seqs":["12"],"wakeKey":"1700:1,1700:2","tasks":["t1"],"wakeNo":1,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{"choice_confidence_floor":0.85},"answers":{"route":{"type":"choice","choice":"routine","confidence":0.9},"no_new_outcome":{"type":"noul","noul":0.05}}}'
    printf '%s\n' '{"t":"2","wake":"signal: A","seqs":["12"],"wakeKey":"1700:1,1700:2","tasks":["t1"],"wakeNo":1,"variant":"without_current_state","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{},"answers":{"route":{"type":"choice","choice":"main","confidence":0.95}}}'
    printf '%s\n' '{"t":"3","wake":"signal: A","seqs":["12"],"wakeKey":"1700:1,1700:2","tasks":["t1"],"wakeNo":1,"variant":"without_prior_outcomes","repeat":1,"control":false,"unavailable":"http 503","requestBytes":10,"ms":5,"policy":{}}'
    printf '%s\n' '{"t":"torn","wake":"signal: B","variant":"fu'
    printf '%s\n' '{"t":"4","wake":"signal: B","seqs":["13"],"wakeKey":"1700:4","tasks":["t1"],"wakeNo":2,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{},"answers":{"route":{"type":"choice","choice":"main","confidence":0.9}}}'
    printf '%s\n' '{"t":"5","wake":"signal: B","seqs":["13"],"wakeKey":"1700:4","tasks":["t1"],"wakeNo":2,"variant":"full","repeat":2,"control":true,"unavailable":null,"requestBytes":10,"ms":5,"policy":{},"answers":{"route":{"type":"choice","choice":"routine","confidence":0.9}}}'
    printf '%s\n' '{"t":"6","wake":"signal: C","seqs":["14"],"wakeKey":"","tasks":["t1"],"wakeNo":3,"variant":"without_pane_tail","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{},"answers":{"route":{"type":"choice","choice":"main","confidence":0.9}}}'
  } > "$state/branch-mod-shadow.jsonl"

  FM_STATE_OVERRIDE="$state" "$SSCORE" > "$out" || fail "shadow scorer failed: $(cat "$out")"
  grep -q '^| full | 2/2 | 0 (0.0%) | 0 (0.0%) | 2 | 0 (0.0%) | 0 |$' "$out" \
    || fail "the route row must score only matched records and skip the repeat control: $(grep '^| full' "$out")"
  grep -q 'unmatched (no outcome row carries this wake key; never counted as a verdict): without_pane_tail=1' "$out" \
    || fail "a record whose wake key matches no outcome row must be reported separately: $(grep unmatched "$out")"
  grep -q '^| without_prior_outcomes | 0/0 | 0 (0.0%) | 0 (0.0%) | 0 | 0 (0.0%) | 1 |$' "$out" \
    || fail "an unavailable record must be counted, not scored: $(grep without_prior_outcomes "$out")"
  grep -q '^| route | 1 | 0 |$' "$out" \
    || fail "the repeat control must score the full-variant pair as raw call noise: $(grep '^| route' "$out")"

  FM_STATE_OVERRIDE="$state" "$SSCORE" -v > "$out" || fail "verbose scorer failed"
  grep -q $'^1700:1,1700:2\tmain\tfull\troute\troutine\troutine\t-' "$out" \
    || fail "the verbose dump must label matched records by wake key: $(grep '1700:1,1700:2' "$out" | head -2)"
  grep -q $'^1700:4\troutine\tfull\troute\tmain\tmain\t-' "$out" \
    || fail "a wake key matching only routine outcome rows must label routine: $(grep '^1700:4' "$out" | head -2)"
  grep -q $'^-\tunmatched\twithout_pane_tail\troute\tmain\tmain\t-' "$out" \
    || fail "the verbose dump must mark records without a matching wake key as unmatched: $(grep unmatched "$out" | head -2)"

  FM_STATE_OVERRIDE="$state" "$SSCORE" "$state/absent.jsonl" > "$out" || fail "scorer failed on an absent log"
  [ "$(wc -l < "$out" | tr -d ' ')" = 3 ] || fail "an absent log prints only the empty route table: $(cat "$out")"
  pass "the shadow scorer joins records to the branch verdict by durable wake key, reports unmatched records separately, skips a torn line in either log, counts unavailable records separately, and scores the repeat control outside the variant rows"
}

test_evidence_bundle_marks_new_lines_and_advances_the_offset
test_routine_covered_lines_surface_only_under_the_mod
test_routine_covered_lines_are_byte_exact_across_outcomes
test_routine_covered_lines_omitted_by_the_byte_cap_are_presented_on_the_next_drain
test_scorer_labels_records_from_the_status_bytes_they_judged
test_scorer_prefers_a_captured_evidence_copy_and_falls_back_to_byte_ranges
test_shadow_jev_helper_keeps_the_key_off_argv_and_the_child_env
test_shadow_pane_helper_reports_only_what_it_can_read
test_shadow_scorer_joins_records_to_outcomes_by_wake_identity
test_gates_scorer_joins_full_records_to_outcomes_facts_and_derivable_actions
test_gates_scorer_sufficiency_mode_judges_evidence_against_the_caller_bound
