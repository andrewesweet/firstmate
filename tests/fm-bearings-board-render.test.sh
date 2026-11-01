#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits, and records that
  # session in this home's own store. The listener resolves its server from that
  # store; the machine-wide default has no session for this board.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.80\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1:4387/session/0123456789abcdef",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # The build's listening sample can land before this process resolves a
    # session. Recording entry makes that gap observable: a claim that dies
    # without reaching poll is not a listener.
    printf 'entered\n' > "$FM_HOME/stub-poll"
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    jq -n --arg file "$real" \
      '{sessions:{"0123456789abcdef":{file:$file,url:"http://127.0.0.1:4387/session/0123456789abcdef"}}}' \
      > "$LAVISH_AXI_STATE_DIR/state.json"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# The build treats a claimed runner as listening before that runner resolves a
# Lavish session. Wait until the stub poll is entered or the source is no longer
# live, and require both: a claim that dies in the gap is the flake.
require_listener_reached_poll() {  # <home>
  local home=$1 i=0 owner=''
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    owner=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
      LAVISH_AXI_STATE_DIR="$home/lavish-state" \
      "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
      | awk 'NR > 1 { print $3; exit }')
    if [ -s "$home/stub-poll" ] && [ "$owner" = live ]; then
      return 0
    fi
    case "$owner" in
      none|orphaned)
        if [ -s "$home/stub-poll" ]; then
          fail "the board listener reached the Lavish poll and then exited (owner: $owner)"
        fi
        fail "the board listener exited before it reached the Lavish poll (owner: $owner)"
        ;;
    esac
    sleep 0.05
  done
  fail "the board listener did not reach the Lavish poll (owner: ${owner:-none})"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} calls=${6:-[]} selection=${7:-} landed=${8:-[]} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" --argjson calls "$calls" --argjson landed "$landed" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:$calls, underway:$underway, landed:$landed,
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  require_listener_reached_poll "$home"
  node "$HARNESS" "$home/.lavish/bearings-board.html" "$selection" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_captured_choices_preserve_recorded_option_labels() {
  local home out
  home=$(make_home captured-label)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"recorded-choice","type":"decision","repo":"sample","title":"Recorded option","options":[
      {"value":"option-0-A-B","label":"A/B"},
      {"value":"option-1-A-B","label":"A-B"}
    ]}
  ]' option-0-A-B)
  jq -e '
    .error == "" and (.queued | length) == 1
    and .queued[0].text == "Recorded option -> A/B"
    and .queued[0].data == {schema:"fm-bearings-answer.v1",question:"recorded-choice",selection:"option-0-A-B",note:""}
  ' <<<"$out" >/dev/null || fail "captured answer lost the recorded label: $out"
  pass "captured choices preserve the label beside the distinct selection value"
}

captured_result() {
  jq -r '
    "prompts[\(.queued | length)]{uid,prompt,selector,tag,text}:",
    (.queued | to_entries[] | "  " + ([ (.key | tostring), (.value.prompt + "\n\nContext data:\n" + (.value.data | tojson)), "form", .value.tag, .value.text] | map(tojson) | join(",")))'
}

test_nonlocal_choices_never_enter_local_answers_or_reconciles() {
  local home out answers reconciles
  home=$(make_home owned-answer)
  out=$(render_board "$home" '[]' '[
    {"id":"mate/ready","owner":"mate","repo":"sample","title":"Mate ready","reason":"ready","dispatchable":true,"filed":"2026-10-30"},
    {"id":"mate/blocked","owner":"mate","repo":"sample","title":"Mate blocked","reason":"blocked","dispatchable":false,"filed":"2026-10-31"}
  ]' 0 0 '[
    {"key":"t-dec","type":"decision","repo":"sample","title":"Main call","options":[{"value":"yes","label":"Yes"}]},
    {"key":"mate/t-dec","owner":"mate","type":"decision","repo":"sample","title":"Mate call","options":[{"value":"yes","label":"Yes"}]}
  ]' yes '[{"id":"t-dec","owner":"(main)","repo":"sample","what":"Main delivery"}]')
  jq -e '.error == "" and .queued[0].data.question == "mate/t-dec" and .queued[0].data.owner == "mate"
    and [.charted[].title] == ["Mate blocked","Mate ready"]' <<<"$out" >/dev/null || fail "nonlocal identity, stale check or ordering failed: $out"
  captured_result <<<"$out" > "$home/result.toon"
  answers=$(bash "$ROOT/bin/fm-procevent-lavish.sh" answers "$home/result.toon") || fail "nonlocal answer extraction failed"
  [ -z "$answers" ] || fail "nonlocal answer reached local intake: $answers"
  jq '.queued[0].data.question = "t-dec" | .queued[0].data.selection = "reconcile"' <<<"$out" | captured_result > "$home/result.toon"
  reconciles=$(bash "$ROOT/bin/fm-procevent-lavish.sh" reconciles "$home/result.toon") || fail "nonlocal reconcile extraction failed"
  [ -z "$reconciles" ] || fail "nonlocal reconcile reached local intake: $reconciles"
  jq '.queued[0].data.selection = "yes" | .queued[0].data.question = "t-dec"' <<<"$out" | captured_result > "$home/result.toon"
  answers=$(bash "$ROOT/bin/fm-procevent-lavish.sh" answers "$home/result.toon") || fail "owner extraction failed"
  [ -z "$answers" ] || fail "unqualified nonlocal answer reached local intake: $answers"
  local representation landed_id
  for representation in raw qualified; do
    home=$(make_home "mate-landed-$representation")
    landed_id=t-dec
    [ "$representation" != qualified ] || landed_id=mate/t-dec
    out=$(render_board "$home" '[]' '[]' 0 0 '[
      {"key":"t-dec","type":"decision","repo":"sample","title":"Main call","options":[{"value":"yes","label":"Yes"}]},
      {"key":"mate/t-dec","owner":"mate","type":"decision","repo":"sample","title":"Mate call","options":[{"value":"yes","label":"Yes"}]}
    ]' yes "$(jq -nc --arg id "$landed_id" '[{id:$id,owner:"mate",repo:"sample",what:"Mate delivery"}]')")
    jq -e '.error == "" and .queued[0].data.question == "t-dec"' <<<"$out" >/dev/null || fail "$representation mate landing removed a colliding main call: $out"
  done
  pass "owner-qualified stale checks keep colliding homes separate; nonlocal captures stay out of local intake"
}

test_local_work_answer_preserves_release_mode() {
  local home out answer
  home=$(make_home release-answer)
  out=$(render_board "$home" '[]' '[]' 0 0 '[
    {"key":"work-gate","owner":"(main)","type":"decision","repo":"sample","title":"Approve work","close":"release","options":[{"value":"approve","label":"Approve"}]}
  ]' approve)
  captured_result <<<"$out" > "$home/result.toon"
  answer=$(bash "$ROOT/bin/fm-procevent-lavish.sh" answers "$home/result.toon") || fail "release answer extraction failed"
  [ "$answer" = "$(printf 'work-gate\tapprove\tApprove work -> Approve\trelease')" ] || fail "work approval lost release mode: $answer"
  pass "rendered work approvals reach the existing intake with release mode"
}

test_recorded_landed_artifacts_are_visible() {
  local home out
  home=$(make_home landed-artifacts)
  out=$(render_board "$home" '[]' '[]' 0 0 '[]' '' '[
    {"id":"pr","owner":"(main)","repo":"sample","what":"Merged work","artifact":"https://github.com/example/sample/pull/42"},
    {"id":"mate/report","owner":"mate","repo":"sample","what":"Research","artifact":"data/report/report.md"}
  ]')
  jq -e '.error == "" and .landed[0].artifacts == [{text:"https://github.com/example/sample/pull/42",href:"https://github.com/example/sample/pull/42"}]
    and .landed[1].artifacts == [{text:"data/report/report.md",href:null}]' <<<"$out" >/dev/null || fail "recorded artifacts disappeared from rendered board: $out"
  pass "the built board renders snapshot PR URLs as links and report artifacts as recorded"
}

test_topic_output_builds_and_renders_through_the_real_board() {
  local home out mate answer
  home=$(make_home topic-integration)
  mkdir -p "$home/mate/data"
  printf -- '- topic | aliases: alias | projects: sample\n' > "$home/data/topics.md"
  printf -- '- mate - Fixture (home: %s/mate; scope: test; projects: sample; added 2026-10-01)\n' "$home" > "$home/data/secondmates.md"
  cat > "$home/main.json" <<'EOF'
[
  {"id":"t-dec","kind":"ship","state":"in_flight","repo":"sample","title":"Main approval","hold_kind":"captain","hold_reason":"Question: approve? options: approve | wait"},
  {"id":"stale-gate","kind":"captain","state":"queued","repo":"sample","title":"Already landed subject","hold_kind":"captain","hold_reason":"Question: approve landed PR?","links":["pr:https://github.com/example/sample/pull/42"]},
  {"id":"other-gate","kind":"captain","state":"queued","repo":"sample","title":"Different PR subject","hold_kind":"captain","hold_reason":"Question: approve other PR?","links":["pr:https://github.com/example/sample/pull/43"]},
  {"id":"old","state":"queued","repo":"sample","title":"Older ready","created":"2026-10-20"},
  {"id":"new","state":"queued","repo":"sample","title":"Newer blocked","created":"2026-10-30","blocked_by":["old"]},
  {"id":"flight","state":"in_flight","kind":"ship","repo":"sample","title":"Flight"},
  {"id":"landed","state":"done","kind":"ship","repo":"sample","title":"","closed":"2026-10-29"}
]
EOF
  cat > "$home/mate.json" <<'EOF'
[
  {"id":"t-dec","kind":"captain","state":"queued","repo":"external","labels":["topic:alias"],"title":"Mate question","hold_kind":"captain","hold_reason":"Question: next? options: wait | continue"},
  {"id":"next","state":"queued","repo":"sample","title":"Mate next","created":"2026-10-31"},
  {"id":"blocked","state":"queued","repo":"sample","title":"Mate blocked","created":"2026-10-30","blocked_by":["next"]},
  {"id":"report","state":"done","kind":"scout","repo":"sample","title":"Mate report","closed":"2026-10-28"}
]
EOF
  cat > "$home/snapshot.json" <<'EOF'
{
  "in_flight":[{"id":"flight","kind":"ship","state":"working","repo":"sample","name":"","doing":""}],
  "recorded_prs":[],
  "landed":[{"id":"landed","owner":"(main)","artifact":"https://github.com/example/sample/pull/42"},{"id":"report","owner":"mate","artifact":"data/report/report.md"}],
  "secondmates":[{"id":"offline","state":"unknown","freshness":"unavailable","reason":"ledger unavailable"}]
}
EOF
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
fixture="$TOPIC_FIXTURE_HOME/main.json"
case "$TASKS_AXI_FILE" in */mate/data/backlog.md) fixture="$TOPIC_FIXTURE_HOME/mate.json" ;; esac
printf '%s\n' "$TASKS_AXI_FILE $*" >> "$TOPIC_FIXTURE_HOME/task-calls"
case "${1:-}" in list|show) ;; *) exit 9 ;; esac
jq -r --arg command "$1" --arg id "${2:-}" '
  def cell:
    (if type == "array" then if length == 0 then "none" else join(",") end
     elif . == null then "-" else tostring end) | tojson;
  if $command == "show" then
    "task:", (.[] | select(.id == $id) | to_entries[] | "  " + .key + ": " + (.value | cell))
  elif length == 0 then
    "count: 0", "tasks: 0 tasks in this backlog"
  else
    ["id","state","kind","repo","title","labels","blocked_by","created","closed","held","hold_kind","hold_until","links","hold_reason"] as $fields |
    "count: \(length)", "tasks[\(length)]{\($fields | join(","))}:",
    (.[] | . as $row | "  " + ([$fields[] | $row[.] | cell] | join(",")))
  end' "$fixture"
SH
  cat > "$home/fakebin/topic-snapshot" <<'SH'
#!/usr/bin/env bash
cat "$TOPIC_FIXTURE_HOME/snapshot.json"
SH
  chmod +x "$home/fakebin/tasks-axi" "$home/fakebin/topic-snapshot"
  TOPIC_FIXTURE_HOME="$home" PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_TOPIC_SNAPSHOT="$home/fakebin/topic-snapshot" FM_TOPIC_NOW=2026-11-01T09:00:00Z FM_TOPIC_BOARD_CMD="$BOARD" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" LAVISH_AXI_STATE_DIR="$home/lavish-state" \
    bash "$ROOT/bin/fm-topic-brief.sh" topic --board > "$home/chat" || fail "topic payload failed the real board consumer"
  require_listener_reached_poll "$home"
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html" option-0-approve t-dec) || fail "topic board did not render"
  jq -e '
    .error == ""
    and .questions == ["t-dec","other-gate","mate/t-dec"]
    and .queued[0].data.close == "release"
    and [.charted[] | select(.pickable) | .title] == ["Mate next","Older ready"]
    and ([.charted[] | select(.badges | any(.text == "needs repair"))] | length) == 1
    and any(.charted[]; (.sub | contains("offline") and contains("ledger unavailable")) and (.pickable | not))
    and (.stats[] | select(.label == "charted next") | .n) == 4
    and .underway[0].title == "flight" and (.underway[0].sub | contains("working") and contains("sample"))
    and .landed[0].title == "landed" and .landed[0].artifacts[0].href == "https://github.com/example/sample/pull/42"
    and .landed[1].artifacts[0].text == "data/report/report.md"
  ' <<<"$out" >/dev/null || fail "topic fields did not survive real board rendering: $out"
  mate=$(node "$HARNESS" "$home/.lavish/bearings-board.html" option-0-wait mate/t-dec) || fail "mate card did not render"
  captured_result <<<"$mate" > "$home/mate-result.toon"
  answer=$(bash "$ROOT/bin/fm-procevent-lavish.sh" answers "$home/mate-result.toon") || fail "mate capture failed"
  [ -z "$answer" ] || fail "mate topic card entered local mutation intake"
  pass "real topic board preserves owners, release mode, dates, empty fields, artifacts and visible coverage alarms"
}

test_long_option_labels_do_not_consume_answer_protocol_budget() {
  local home out label calls note answer
  home=$(make_home long-option)
  label=$(jq -nr '"é" * 300')
  calls=$(jq -nc --arg label "$label" '[{key:"long-option",type:"decision",repo:"sample",title:"Long option",options:[{value:"approve",label:$label}],allow_freeform:true}]')
  out=$(render_board "$home" '[]' '[]' 0 0 "$calls" approve)
  jq -e --arg label "$label" '.error == "" and any(.options[]; . == $label) and .queued[0].text == ("Long option -> " + $label) and .queued[0].data.selection == "approve"' <<<"$out" >/dev/null || fail "600-byte label blocked or lost an otherwise valid answer: $out"
  captured_result <<<"$out" > "$home/result.toon"
  answer=$(bash "$ROOT/bin/fm-procevent-lavish.sh" answers "$home/result.toon") || fail "long-label answer extraction failed"
  [ "$(printf '%s' "$answer" | cut -f1-2)" = "$(printf 'long-option\tapprove')" ] || fail "long label prevented the selection reaching intake"
  note=$(jq -nr '"x" * 512')
  out=$(node "$HARNESS" "$home/.lavish/bearings-board.html" '' long-option "$note") || fail "freeform submission failed"
  jq -e --arg note "$note" '.queued[0].data.note == $note' <<<"$out" >/dev/null || fail "512-byte freeform answer was rejected"
  for note in "$(jq -nr '"x" * 513')" "$(jq -nr '"🙂" * 129')"; do
    out=$(node "$HARNESS" "$home/.lavish/bearings-board.html" '' long-option "$note") || fail "over-limit submission failed"
    jq -e '.queued | length == 0' <<<"$out" >/dev/null || fail "over-512-byte note was captured"
    out=$(node "$HARNESS" "$home/.lavish/bearings-board.html" approve long-option "$note") || fail "over-limit selection/note submission failed"
    jq -e '.queued | length == 0' <<<"$out" >/dev/null || fail "over-limit selected answer/note was captured"
  done
  pass "whole 600-byte option labels remain selectable while the submitted selection/note retains its 512-byte guard"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering

test_captured_choices_preserve_recorded_option_labels

test_nonlocal_choices_never_enter_local_answers_or_reconciles
test_local_work_answer_preserves_release_mode
test_recorded_landed_artifacts_are_visible

test_topic_output_builds_and_renders_through_the_real_board

test_long_option_labels_do_not_consume_answer_protocol_budget
