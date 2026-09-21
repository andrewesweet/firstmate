#!/usr/bin/env bash
# Tests for bin/fm-retro-trigger.sh, the durable retrospective trigger:
# opt-in config parsing (inert without config/retro-cadence, loud on a
# malformed one), idempotent closure and anomaly receipts, the three firing
# rules (any anomaly, known-lane spend, median multiple), exactly-one queued
# row plus exactly-one check wake per generation with open-row absorption,
# the done-unseen epoch binding in fm-wake-lib.sh's presentation hook, reset
# archiving, and the two producers never failing their host operations
# (teardown's closure receipt, the wake-lib annotation hook).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RT="$ROOT/bin/fm-retro-trigger.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
CLASSIFY_LIB="$ROOT/bin/fm-classify-lib.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
REAL_TASKS_AXI=$(command -v tasks-axi || true)
TASKS_AXI_AVAILABLE=0
[ -n "$REAL_TASKS_AXI" ] && TASKS_AXI_AVAILABLE=1

TMP_ROOT=$(fm_test_tmproot fm-retro-trigger)

# rt_home <name>: a fresh fixture home with config/, state/, and data/.
rt_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf '%s\n' "$home"
}

# rt_run <home> <args...>: run the trigger against a fixture home with every
# override pinned, so no test can touch the real repo's records.
rt_run() {
  local home=$1
  shift
  FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$RT" "$@"
}

# rt_config <home> <lines...>: write the cadence config from separate lines.
rt_config() {
  local home=$1 line
  shift
  : > "$home/config/retro-cadence"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/config/retro-cadence"
  done
}

# rt_seed_open_generation <home> <gen>: hand-seed a generation whose trigger
# row is already open, so observations append receipts and never file rows.
rt_seed_open_generation() {
  local home=$1 gen=$2
  mkdir -p "$home/state/retro-trigger/receipts/$gen"
  printf '%s\n' "$gen" > "$home/state/retro-trigger/generation"
  printf 'retro-trigger-%s\n' "$gen" > "$home/state/retro-trigger/open-row"
}

rt_receipt_count() {  # <home> -> number of receipts in the current generation
  local home=$1 gen count=0 f
  gen=$(cat "$home/state/retro-trigger/generation" 2>/dev/null)
  [ -n "$gen" ] || { printf '0'; return 0; }
  for f in "$home/state/retro-trigger/receipts/$gen"/*.receipt; do
    [ -f "$f" ] || break
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

rt_wake_rows() {  # <home> -> the durable wake queue's line count
  if [ -f "$1/state/.wake-queue" ]; then
    wc -l < "$1/state/.wake-queue" | tr -d ' '
  else
    printf '0'
  fi
}

rt_backlog_rows() {  # <home> -> count of filed trigger rows in the backlog
  if [ -f "$1/data/backlog.md" ]; then
    grep -c '^- \[ \] retro-trigger-' "$1/data/backlog.md" || true
  else
    printf '0'
  fi
}

rt_skip_unless_fire() {  # <test-name>: firing needs the real tasks-axi
  [ "$TASKS_AXI_AVAILABLE" = 1 ] || { pass "skipped, tasks-axi absent: $1"; return 1; }
  return 0
}

test_inert_without_config() {
  local home out
  home=$(rt_home inert)
  out=$(rt_run "$home" status 2>&1)
  expect_code 0 "$?" "inert: status without config must be a silent no-op"
  [ -z "$out" ] || fail "inert: status without config printed: $out"
  rt_run "$home" observe closure task-a >/dev/null 2>&1
  rt_run "$home" observe anomaly blocked task-a evidence >/dev/null 2>&1
  rt_run "$home" reset retro-1 >/dev/null 2>&1
  assert_absent "$home/state/retro-trigger" \
    "inert: an observe or reset without config created the store"
  pass "absent config makes every command a silent no-op that creates nothing"
}

test_malformed_config_is_a_loud_refusal() {
  local home out
  home=$(rt_home malformed)
  rt_config "$home" "bogus_key=1"
  out=$(rt_run "$home" status 2>&1)
  expect_code 2 "$?" "malformed: an unknown key must refuse with exit 2"
  assert_contains "$out" "unknown key: bogus_key" \
    "malformed: the refusal did not name the unknown key"
  rt_config "$home" "spend_usd=abc"
  out=$(rt_run "$home" status 2>&1)
  expect_code 2 "$?" "malformed: a non-numeric spend_usd must refuse with exit 2"
  assert_contains "$out" "spend_usd" "malformed: the refusal did not name the key"
  rt_config "$home" "spend_usd=1.2.3"
  rt_run "$home" status >/dev/null 2>&1
  expect_code 2 "$?" "malformed: a two-dot spend_usd must refuse"
  rt_config "$home" "done_unseen_minutes=0"
  rt_run "$home" status >/dev/null 2>&1
  expect_code 2 "$?" "malformed: a zero done_unseen_minutes must refuse"
  rm "$home/config/retro-cadence"
  ln -s "$home/config/elsewhere" "$home/config/retro-cadence"
  out=$(rt_run "$home" status 2>&1)
  expect_code 2 "$?" "malformed: a symlinked config must refuse"
  pass "an unknown key or malformed value is a loud refusal naming the key"
}

test_closure_receipts_are_idempotent_with_two_lanes() {
  local home gen known unknown
  home=$(rt_home closures)
  rt_config "$home" "spend_usd=10000"
  rt_run "$home" observe closure ship-a --cost 5 || fail "closure: --cost observe failed"
  rt_run "$home" observe closure ship-b || fail "closure: unknown-lane observe failed"
  rt_run "$home" observe closure ship-a --cost 999 \
    || fail "closure: the repeat observe failed"
  gen=$(cat "$home/state/retro-trigger/generation")
  known=$(grep -l '^lane=known$' "$home/state/retro-trigger/receipts/$gen"/*.receipt 2>/dev/null | wc -l)
  unknown=$(grep -l '^lane=unknown$' "$home/state/retro-trigger/receipts/$gen"/*.receipt 2>/dev/null | wc -l)
  [ "$known" -eq 1 ] || fail "closure: expected exactly one known-lane receipt, got $known"
  [ "$unknown" -eq 1 ] || fail "closure: expected exactly one unknown-lane receipt, got $unknown"
  assert_equals "2" "$(rt_receipt_count "$home")" \
    "closure: the repeat observe of ship-a must not add a receipt"
  pass "closure receipts are idempotent per task id across both cost lanes"
}

test_open_row_absorbs_every_later_observe() {
  local home before after
  home=$(rt_home absorb)
  rt_config "$home" "spend_usd=10000"
  rt_seed_open_generation "$home" g1
  rt_run "$home" observe anomaly blocked t1 "first evidence"
  rt_run "$home" observe anomaly blocked t1 "first evidence"
  rt_run "$home" observe anomaly needs-decision t2 "[key=k1] other"
  rt_run "$home" observe closure t3 --cost 400
  before=$(rt_receipt_count "$home")
  rt_run "$home" observe closure t4
  after=$(rt_receipt_count "$home")
  assert_equals "3" "$before" "absorb: expected 3 receipts before the last observe, got $before"
  assert_equals "4" "$after" "absorb: the last observe must still append its receipt"
  assert_equals "0" "$(rt_wake_rows "$home")" \
    "absorb: an open row must never enqueue a wake"
  assert_equals "0" "$(rt_backlog_rows "$home")" \
    "absorb: an open row must mean no backlog filing"
  pass "while the trigger row is open, observes append receipts and nothing else"
}

test_spend_rule_fires_exactly_once() {
  local home open wake
  rt_skip_unless_fire "spend rule" || return 0
  home=$(rt_home spend)
  rt_config "$home" "spend_usd=10"
  rt_run "$home" observe closure ship-a --cost 3 >/dev/null 2>&1
  [ -f "$home/state/retro-trigger/open-row" ] \
    && fail "spend: 3 USD must not reach the 10 USD threshold"
  rt_run "$home" observe closure ship-b --cost 8 >/dev/null 2>&1
  assert_present "$home/state/retro-trigger/open-row" \
    "spend: reaching the threshold must open the trigger row"
  open=$(cat "$home/state/retro-trigger/open-row")
  assert_equals "retro-trigger-$(cat "$home/state/retro-trigger/generation")" "$open" \
    "spend: the open row must be retro-trigger-<generation>"
  assert_equals "1" "$(rt_wake_rows "$home")" \
    "spend: firing must enqueue exactly one wake"
  wake=$(awk -F '\t' '{print $5}' "$home/state/.wake-queue")
  assert_contains "$wake" "retro trigger" \
    "spend: the queued wake must be a check wake naming the trigger"
  assert_equals "1" "$(rt_backlog_rows "$home")" \
    "spend: firing must file exactly one backlog row"
  pass "known-lane spend reaching spend_usd files one row and one check wake"
}

test_median_rule_bounds_and_fires() {
  local home
  rt_skip_unless_fire "median rule" || return 0
  home=$(rt_home median)
  rt_config "$home" "spend_usd=100000" "median_multiplier=2"
  rt_run "$home" observe closure a --cost 10 >/dev/null 2>&1
  rt_run "$home" observe closure b --cost 12 >/dev/null 2>&1
  rt_run "$home" observe closure c --cost 24 >/dev/null 2>&1
  [ -f "$home/state/retro-trigger/open-row" ] \
    && fail "median: 24 is exactly 2x the median 12 and must not fire"
  rt_run "$home" observe closure d --cost 25 >/dev/null 2>&1
  [ -f "$home/state/retro-trigger/open-row" ] \
    && fail "median: 25 vs median 17 of 10,12,24,25 is below 2x and must not fire"
  rt_run "$home" observe closure e --cost 500 >/dev/null 2>&1
  assert_present "$home/state/retro-trigger/open-row" \
    "median: 500 vs median 18 of 10,12,24,25,500 exceeds 2x and must fire"
  pass "the median rule needs three known closures and a cost over the multiple"
}

test_anomaly_rule_fires_and_is_idempotent() {
  local home gen count
  rt_skip_unless_fire "anomaly rule" || return 0
  home=$(rt_home anomaly)
  rt_config "$home" "spend_usd=10000"
  rt_run "$home" observe anomaly blocked t1 "first evidence" >/dev/null 2>&1
  assert_present "$home/state/retro-trigger/open-row" \
    "anomaly: any anomaly must fire"
  rt_run "$home" reset r1 >/dev/null 2>&1
  rt_run "$home" observe anomaly blocked t1 "first evidence" >/dev/null 2>&1
  rt_run "$home" observe anomaly blocked t1 "first evidence" >/dev/null 2>&1
  rt_run "$home" observe anomaly blocked t1 "second evidence" >/dev/null 2>&1
  gen=$(cat "$home/state/retro-trigger/generation")
  count=$(ls "$home/state/retro-trigger/receipts/$gen" | grep -c '^anomaly-blocked-')
  assert_equals "2" "$count" \
    "anomaly: idempotency is per (kind, task, evidence); expected 2 receipts, got $count"
  pass "an anomaly receipt fires the trigger and dedupes on kind, task, and evidence"
}

test_failed_wake_enqueue_is_retried_by_the_next_observe() {
  local home
  rt_skip_unless_fire "wake retry" || return 0
  home=$(rt_home wake-retry)
  rt_config "$home" "spend_usd=10000"
  mkdir "$home/state/.wake-queue"
  rt_run "$home" observe anomaly blocked t1 "first evidence" >/dev/null 2>&1 \
    && fail "wake retry: a failed wake enqueue must exit non-zero"
  assert_equals "1" "$(rt_backlog_rows "$home")" \
    "wake retry: the backlog row must land before the wake"
  [ -e "$home/state/retro-trigger/open-row" ] \
    && fail "wake retry: no open-row marker may exist while the wake is unqueued"
  rmdir "$home/state/.wake-queue"
  rt_run "$home" observe anomaly blocked t2 "second evidence" >/dev/null 2>&1 \
    || fail "wake retry: the next observe must fire cleanly"
  assert_equals "1" "$(rt_wake_rows "$home")" \
    "wake retry: the next observe must enqueue the check wake"
  assert_present "$home/state/retro-trigger/open-row" \
    "wake retry: the marker must land once the wake is queued"
  assert_equals "1" "$(rt_backlog_rows "$home")" \
    "wake retry: the retried firing must not file a second backlog row"
  pass "a failed wake enqueue leaves no marker and the next observe retries without a second row"
}

test_done_unseen_threshold_is_script_owned() {
  local home now out
  home=$(rt_home done-unseen)
  rt_config "$home" "done_unseen_minutes=30"
  now=$(date +%s)
  out=$(rt_run "$home" observe anomaly done-unseen t1 "epoch=$((now - 60)) done: x" 2>&1)
  expect_code 0 "$?" "done-unseen: an under-threshold observation must succeed silently"
  [ -z "$out" ] || fail "done-unseen: an under-threshold observation printed: $out"
  assert_absent "$home/state/retro-trigger" \
    "done-unseen: an observation under the threshold must record nothing"
  rt_run "$home" observe anomaly done-unseen t2 "done without epoch" >/dev/null 2>&1
  expect_code 2 "$?" "done-unseen: evidence without an epoch must be a loud refusal"
  if [ "$TASKS_AXI_AVAILABLE" = 1 ]; then
    rt_run "$home" observe anomaly done-unseen t1 "epoch=$((now - 3600)) done: x" \
      >/dev/null 2>&1
    assert_present "$home/state/retro-trigger/open-row" \
      "done-unseen: an observation past the threshold must fire"
  fi
  pass "done-unseen observations apply the threshold and require a bound epoch"
}

test_status_reports_the_generation() {
  local home out
  home=$(rt_home status)
  rt_config "$home" "spend_usd=10000"
  out=$(rt_run "$home" status)
  assert_contains "$out" "generation: -" "status: an empty store has no generation"
  rt_run "$home" observe closure a --cost 7 >/dev/null 2>&1
  rt_run "$home" observe closure b >/dev/null 2>&1
  out=$(rt_run "$home" status)
  assert_contains "$out" "known_spend: 7.00" "status: known spend must sum the known lane"
  assert_contains "$out" "known_closures: 1" "status: one known closure expected"
  assert_contains "$out" "unknown_closures: 1" "status: one unknown closure expected"
  assert_contains "$out" "median_known_cost: 7.00" "status: median of one cost is the cost"
  assert_contains "$out" "anomalies: 0" "status: no anomalies expected"
  assert_contains "$out" "open_row: -" "status: nothing fired so no open row"
  pass "status reports lanes, spend, median, anomalies, and the open row"
}

test_reset_archives_and_starts_a_new_generation() {
  local home gen archived new_gen
  home=$(rt_home reset)
  rt_config "$home" "spend_usd=10000"
  rt_seed_open_generation "$home" g1
  rt_run "$home" observe anomaly blocked t1 "evidence one" >/dev/null 2>&1 \
    || fail "reset: observe failed"
  rt_run "$home" reset sprint-7 >/dev/null 2>&1
  [ -d "$home/state/retro-trigger/archive/sprint-7" ] \
    || fail "reset: the generation receipts must move under archive/<retro-id>"
  assert_absent "$home/state/retro-trigger/receipts/g1" \
    "reset: the old generation receipts must leave receipts/"
  assert_absent "$home/state/retro-trigger/open-row" \
    "reset: the open row must clear"
  assert_grep "g1" "$home/state/retro-trigger/archive/sprint-7/generation" \
    "reset: the archive must name the generation it holds"
  new_gen=$(cat "$home/state/retro-trigger/generation")
  [ "$new_gen" != "g1" ] || fail "reset: a new generation must start"
  rt_run "$home" observe anomaly blocked t2 "evidence two" >/dev/null 2>&1 \
    || fail "reset: re-observe failed"
  assert_equals "1" "$(rt_receipt_count "$home")" \
    "reset: the re-observe must land in the new generation"
  rt_run "$home" reset sprint-7 >/dev/null 2>&1
  archived=$(ls -d "$home/state/retro-trigger/archive"/sprint-7-* 2>/dev/null | wc -l)
  [ "$archived" -ge 1 ] || fail "reset: a repeated retro id must archive beside the first"
  assert_equals "0" "$(rt_receipt_count "$home")" \
    "reset: the second archive starts another empty generation"
  pass "reset archives the generation under the retro id and starts the next one"
}

# --- producers: the wake-lib presentation hook ------------------------------

# rt_annotate <home> <status-key> <status-content> <row-epoch>: seed one direct
# signal row with the given durable epoch and run the presentation the way the
# drain does, with the classify cursor available.
rt_annotate() {
  local home=$1 status_key=$2 content=$3 epoch=$4 out
  printf '%s\n' "$content" > "$home/state/$status_key"
  printf '%s\t1\tsignal\t%s\tsignal: x\n' "$epoch" "$status_key" \
    > "$home/state/.wake-queue"
  out=$(FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" bash -c '
      . "$1"
      . "$2"
      rows=$(fm_wake_print_deduped "$3")
      fm_wake_print_annotations "$rows"
    ' _ "$CLASSIFY_LIB" "$WAKE_LIB" "$home/state/.wake-queue" 2>&1)
  printf '%s\n' "$out"
}

test_hook_is_inert_without_config_and_never_fails_the_drain() {
  local home out
  home=$(rt_home hook-inert)
  out=$(rt_annotate "$home" crew.status "needs-decision: pick [key=k]" 1790000000)
  assert_contains "$out" "wake annotation:" \
    "hook: the annotation itself must still print without config"
  assert_absent "$home/state/retro-trigger" \
    "hook: without config the producer must create nothing"
  pass "without config the annotation hook prints annotations and creates nothing"
}

test_hook_records_needs_decision_with_key_evidence() {
  local home gen receipt
  home=$(rt_home hook-nd)
  rt_config "$home" "spend_usd=10000"
  rt_seed_open_generation "$home" g1
  out=$(rt_annotate "$home" crew.status "needs-decision: pick a name [key=cap-9]" 1790000000)
  assert_contains "$out" "wake annotation:" \
    "hook: the needs-decision annotation must still print"
  receipt=$(grep -l '^kind=needs-decision$' \
    "$home/state/retro-trigger/receipts/g1"/*.receipt 2>/dev/null | head -1)
  assert_present "$receipt" "hook: the presented needs-decision line must record a receipt"
  assert_grep "evidence=cap-9" "$receipt" \
    "hook: the receipt evidence must carry the line's [key=...] decision key"
  pass "the hook turns a presented needs-decision line into a keyed receipt"
}

test_hook_done_unseen_epoch_binding() {
  local home now old receipt count out
  now=$(date +%s)
  old=$((now - 3600))
  # Single unread line plus a single direct signal row: the row is
  # unambiguously the wake that carried this done line, so its epoch binds.
  home=$(rt_home hook-done)
  rt_config "$home" "spend_usd=10000" "done_unseen_minutes=30"
  rt_seed_open_generation "$home" g1
  out=$(rt_annotate "$home" crew.status "done: PR https://example.test/1" "$old")
  assert_contains "$out" "wake annotation:" "hook: the done annotation must still print"
  receipt=$(grep -l '^kind=done-unseen$' \
    "$home/state/retro-trigger/receipts/g1"/*.receipt 2>/dev/null | head -1)
  assert_present "$receipt" "hook: a stale single-line done must record a receipt"
  assert_grep "epoch=$old" "$receipt" \
    "hook: the done-unseen receipt must name the bound wake row epoch"
  # A multi-line span cannot bind the done line to one row: no receipt.
  home=$(rt_home hook-done-multi)
  rt_config "$home" "spend_usd=10000" "done_unseen_minutes=30"
  rt_seed_open_generation "$home" g1
  printf 'working: still going\ndone: PR https://example.test/2\n' > "$home/state/crew.status"
  printf '%s\t1\tsignal\tcrew.status\tsignal: x\n' "$old" > "$home/state/.wake-queue"
  FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" bash -c '
      . "$1"
      . "$2"
      rows=$(fm_wake_print_deduped "$3")
      fm_wake_print_annotations "$rows"
    ' _ "$CLASSIFY_LIB" "$WAKE_LIB" "$home/state/.wake-queue" >/dev/null 2>&1
  count=$(rt_receipt_count "$home")
  assert_equals "0" "$count" \
    "hook: a multi-line span must stay silent rather than approximate the epoch"
  # A fresh done (epoch seconds old) records nothing at all.
  home=$(rt_home hook-done-fresh)
  rt_config "$home" "spend_usd=10000" "done_unseen_minutes=30"
  rt_seed_open_generation "$home" g1
  out=$(rt_annotate "$home" crew.status "done: PR https://example.test/3" "$now")
  count=$(rt_receipt_count "$home")
  assert_equals "0" "$count" \
    "hook: a fresh done under the threshold must record nothing"
  pass "done-unseen binds only an exact single-line single-row epoch, never approximates"
}

test_hook_replay_is_idempotent_and_failure_is_absorbed() {
  local home gen count out
  rt_skip_unless_fire "hook failure absorption" || return 0
  home=$(rt_home hook-replay)
  rt_config "$home" "spend_usd=10000"
  out=$(rt_annotate "$home" crew.status "needs-decision: pick [key=k2]" 1790000000)
  assert_contains "$out" "wake annotation:" "hook: the first annotation must print"
  gen=$(cat "$home/state/retro-trigger/generation")
  count=$(ls "$home/state/retro-trigger/receipts/$gen" 2>/dev/null | wc -l)
  assert_equals "1" "$count" "hook: the first annotation records one receipt"
  # A presentation replay (crash recovery) must not duplicate the receipt.
  printf '%s\t1\tsignal\tcrew.status\tsignal: x\n' 1790000000 > "$home/state/.wake-queue"
  out=$(rt_annotate "$home" crew.status "needs-decision: pick [key=k2]" 1790000000)
  assert_contains "$out" "wake annotation:" "hook: the replay must still annotate"
  count=$(ls "$home/state/retro-trigger/receipts/$gen" 2>/dev/null | wc -l)
  assert_equals "1" "$count" "hook: the replay must not duplicate the receipt"
  # A failing tasks-axi makes the trigger's own fire fail; the hook absorbs it
  # and the annotation still prints with the receipt durably in place.
  home=$(rt_home hook-fail)
  rt_config "$home" "spend_usd=10000"
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  add) echo "simulated tasks-axi add failure" >&2; exit 1 ;;
esac
exec "$REAL_TASKS_AXI" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  out=$(PATH="$home/fakebin:$PATH" rt_annotate "$home" crew.status \
    "needs-decision: pick [key=k3]" 1790000000)
  assert_contains "$out" "wake annotation:" \
    "hook: a trigger filing failure must never fail the annotation"
  count=$(rt_receipt_count "$home")
  assert_equals "1" "$count" \
    "hook: the receipt stays durable when the trigger filing fails"
  assert_absent "$home/state/retro-trigger/open-row" \
    "hook: a failed filing must leave no open row so the next observe retries"
  pass "a presentation replay dedupes and a trigger failure never fails the drain"
}

# --- producers: the teardown closure hook ----------------------------------

# rt_teardown_case <name>: the minimal ALLOW teardown fixture, from
# tests/fm-teardown.test.sh's merged-into-local-main local-only case, with a
# real in-flight backlog row so the close transition runs.
rt_teardown_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$1"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/curl"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cp "$fakebin/gh-axi" "$fakebin/gh"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/curl" "$fakebin/gh-axi" "$fakebin/gh"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) exit 0 ;;
      abort) exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=rt-teardown-task-x1"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "rt teardown fixture" --kind ship \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
  printf '%s\n' "$case_dir"
}

rt_run_teardown() {  # <case-dir>
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1
}

test_teardown_records_a_closure_receipt_without_failing() {
  local case_dir gen receipt
  rt_skip_unless_fire "teardown closure receipt" || return 0
  case_dir=$(rt_teardown_case rt-td-allow)
  rt_config "$case_dir" "spend_usd=10000"
  rt_run_teardown "$case_dir" >/dev/null 2>&1
  expect_code 0 "$?" "teardown: the closure-producing teardown must succeed"
  gen=$(cat "$case_dir/state/retro-trigger/generation")
  receipt=$(grep -l "^task=task-x1$" \
    "$case_dir/state/retro-trigger/receipts/$gen"/closure-*.receipt 2>/dev/null | head -1)
  assert_present "$receipt" "teardown: a closed ship task must leave a closure receipt"
  assert_grep "lane=unknown" "$receipt" \
    "teardown: today's closure receipt lands in the unknown lane"
  pass "a teardown that closes its backlog records an unknown-lane closure receipt"
}

test_teardown_without_config_stays_inert() {
  local case_dir
  rt_skip_unless_fire "teardown inert case" || return 0
  case_dir=$(rt_teardown_case rt-td-inert)
  rt_run_teardown "$case_dir" >/dev/null 2>&1
  expect_code 0 "$?" "teardown: the inert teardown must succeed"
  assert_absent "$case_dir/state/retro-trigger" \
    "teardown: without config the producer must create nothing"
  pass "teardown without config creates no store and still succeeds"
}

test_teardown_absorbs_a_broken_store() {
  local case_dir rc
  rt_skip_unless_fire "teardown blocked store" || return 0
  case_dir=$(rt_teardown_case rt-td-broken)
  rt_config "$case_dir" "spend_usd=10000"
  # A store that cannot be written makes the trigger's own observe fail
  # loudly; the teardown must still absorb it and close the backlog.
  printf 'not a directory\n' > "$case_dir/state/retro-trigger"
  set +e
  rc=$(rt_run_teardown "$case_dir" >/dev/null 2>&1; echo $?)
  set -e
  expect_code 0 "$rc" \
    "teardown: a broken retro store must never fail the teardown"
  assert_grep "task-x1" "$case_dir/data/backlog.md" \
    "teardown: the backlog close must still have run"
  pass "a teardown absorbs a broken retro store and still closes its backlog"
}

test_inert_without_config
test_malformed_config_is_a_loud_refusal
test_closure_receipts_are_idempotent_with_two_lanes
test_open_row_absorbs_every_later_observe
test_spend_rule_fires_exactly_once
test_median_rule_bounds_and_fires
test_anomaly_rule_fires_and_is_idempotent
test_failed_wake_enqueue_is_retried_by_the_next_observe
test_done_unseen_threshold_is_script_owned
test_status_reports_the_generation
test_reset_archives_and_starts_a_new_generation
test_hook_is_inert_without_config_and_never_fails_the_drain
test_hook_records_needs_decision_with_key_evidence
test_hook_done_unseen_epoch_binding
test_hook_replay_is_idempotent_and_failure_is_absorbed
test_teardown_records_a_closure_receipt_without_failing
test_teardown_without_config_stays_inert
test_teardown_absorbs_a_broken_store
