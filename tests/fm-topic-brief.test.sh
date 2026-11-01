#!/usr/bin/env bash
# Behavior tests for bin/fm-topic-brief.sh, the per-topic briefing command.
# Covers registry parsing and its actionable errors, membership by topic label
# (and alias) with the project-default fallback when the installed tasks-axi
# cannot carry labels, second-mate rows from the same ledger and snapshot,
# the briefing window (default, --since, previous-briefing) with recap,
# open-captain-decision projection with options extraction, the self-contained
# HTML brief with its offline answers line, briefing history, and the
# fm-bearings-board.v1 payload shape.
#
# The no-labels table fixture was captured from tasks-axi list after creating
# the records through the real CLI and setting their durable fixture dates.
# The labeled variant adds the optional labels column to that table contract.
# PATH stubs cover both capabilities; a real-CLI case checks table decoding.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOPIC_BRIEF="$ROOT/bin/fm-topic-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-topic-brief)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

NOW=2026-11-01T09:00:00Z
REAL_TASKS_AXI=$(command -v tasks-axi || true)

# --- fixture builders --------------------------------------------------------

make_home() {  # <name> -> prints home dir; writes registry + fixture state
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/mate/data"
  printf -- '- mate - Fixture secondmate (home: %s/mate; scope: tests; projects: treehouse; added 2026-10-01)\n' "$home" > "$home/data/secondmates.md"
  cat > "$home/data/topics.md" <<'EOF'
# topic registry: - <name> [| aliases: csv] [| projects: csv]
- tf-mut | aliases: tf-mutations, mut | projects: treehouse, firstmate
- crew-wiki | projects: treehouse
EOF
  printf '%s\n' "$home"
}

# A tasks-axi stub whose list output is a pinned TOON fixture. With labels in
# the requested field list it serves the labeled rows; the show subcommand
# serves the held-task detail. Without labels support use make_nolabel_stub.
make_stub_bin() {  # <dir> <mode: labeled|nolabels>
  local dir="$1" mode="$2" fixture
  mkdir -p "$dir"
  case "$mode" in
    labeled) fixture="$TMP_ROOT/list-labels.toon" ;;
    nolabels) fixture="$TMP_ROOT/list-nolabels.toon" ;;
    *) fail "make_stub_bin: unknown mode $mode" ;;
  esac
  cat > "$dir/tasks-axi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/calls.log"
fixture="\${TOPIC_MAIN_FIXTURE:-$fixture}"
case "\${TASKS_AXI_FILE:-}" in */mate/data/backlog.md) fixture="\${TOPIC_MATE_FIXTURE:-$TMP_ROOT/mate-labels.toon}" ;; esac
case "\${3:-}" in
  labels,*)
    if [ "$mode" = nolabels ]; then
      cat "$TMP_ROOT/nolabel-refusal.txt"
      exit 2
    fi
    ;;
esac
case "\${1:-}" in
  list) cat "\$fixture" ;;
  show)
    [ "\${2:-}" = t-dec ] || exit 1
    detail="\${TOPIC_DETAIL_FIXTURE:-$TMP_ROOT/show-t-dec.toon}"
    case "\${TASKS_AXI_FILE:-}" in */mate/data/backlog.md) detail="\${TOPIC_MATE_DETAIL_FIXTURE:-\$detail}" ;; esac
    cat "\$detail"
    ;;
  *) echo "unexpected tasks-axi call: \$*" >&2; exit 9 ;;
esac
EOF
  chmod +x "$dir/tasks-axi"
  cat > "$dir/fmtb-snapshot" <<'EOF'
#!/usr/bin/env bash
cat "$SNAPSHOT_FIXTURE"
EOF
  chmod +x "$dir/fmtb-snapshot"
}

write_toon() {
  jq -r --arg mode "${1:-list}" '
    def cell:
      (if type == "array" then if length == 0 then "none" else join(",") end
       elif . == null then "-" else tostring end) | tojson;
    if $mode == "detail" then
      "task:", (.[0] | to_entries[] | "  " + .key + ": " + (.value | cell))
    elif length == 0 then
      "count: 0", "tasks: 0 tasks in this backlog"
    else
      ["id","state","kind","repo","title","labels","blocked_by","created","closed","held","hold_kind","hold_until","links","hold_reason"] as $fields |
      "count: \(length)", "tasks[\(length)]{\($fields | join(","))}:",
      (.[] | . as $row | "  " + ([$fields[] | $row[.] | cell] | join(",")))
    end'
}

write_fixtures() {
  cp "$ROOT/tests/assets/topic-list-labels.toon" "$TMP_ROOT/list-labels.toon"
  cp "$ROOT/tests/assets/topic-list-nolabels.toon" "$TMP_ROOT/list-nolabels.toon"
  printf 'Unknown field(s): labels. Available: blocked, blocked_by, body, closed, created, delivery_state, deps, held, hold_kind, hold_until, links, hold_reason\n' > "$TMP_ROOT/nolabel-refusal.txt"
  cat > "$TMP_ROOT/show-t-dec.toon" <<'EOF'
task:
  id: t-dec
  state: queued
  kind: ship
  repo: treehouse
  title: "Held member with captain question (full title from detail)"
  labels: "topic:tf-mut"
  blocked_by: none
  created: 2026-10-25
  closed: "-"
  held: yes
  hold_kind: captain
  hold_until: 2026-11-15
  links: "report:data/t-dec/report.md"
  hold_reason: "Question: which merge posture for topic briefings? Full context: the captain asked for topic briefings on 2026-10-20. options: yolo on | yolo off | defer a week"
help[1]:
  - "Run `tasks-axi show <id>` for full notes on a task"
EOF
  cat > "$TMP_ROOT/snapshot.json" <<'EOF'
{
  "schema": "fm-bearings-snapshot.v1",
  "generated": "2026-11-01T08:00:00Z",
  "in_flight": [
    { "id": "t-flight", "kind": "ship", "state": "in_flight", "repo": "treehouse", "name": "Main child in flight", "doing": "landing the pipeline", "owner": "(main)" },
    { "id": "t-other-flight", "kind": "ship", "state": "in_flight", "repo": "other-repo", "name": "Other repo flight", "doing": "work", "owner": "(main)" },
    { "id": "mate/t-flight", "kind": "ship", "state": "in_flight", "repo": "treehouse", "name": "Second-mate child in flight", "doing": "checking labels", "owner": "mate" },
    { "id": "mate/t-nowhere", "kind": "ship", "state": "in_flight", "repo": null, "name": "Second-mate no-repo flight", "doing": "work", "owner": "mate" }
  ],
  "decisions_open": [
    { "id": "t-dec", "verb": "decide", "summary": "main held decision", "repo": "treehouse", "owner": "(main)" },
    { "id": "mate/t-dec2", "verb": "decide", "summary": "second-mate decision", "repo": null, "owner": "mate" }
  ],
  "landed": [
    { "id": "t-done", "what": "Landed member row with PR", "pr_url": "https://github.com/andrewesweet/treehouse/pull/42", "repo": "treehouse", "owner": "(main)" },
    { "id": "t-done2", "what": "Second-mate landed row", "artifact": "data/t-done2/report.md", "owner": "mate" }
  ],
  "recorded_prs": [{ "id": "t-flight", "url": "https://github.com/andrewesweet/treehouse/pull/77" }],
  "secondmates": [{"id":"mate", "state":"active_child_work", "freshness":"fresh"}],
  "omitted": []
}
EOF
  write_toon > "$TMP_ROOT/mate-labels.toon" <<'EOF'
[
  {"id":"t-flight","state":"in_flight","kind":"ship","repo":"treehouse","title":"Second-mate child in flight","labels":[],"held":"no"},
  {"id":"t-nowhere","state":"in_flight","kind":"ship","repo":"-","title":"Second-mate no-repo flight","labels":[],"held":"no"}
]
EOF
}

write_fixtures

run_topic() {  # <home> <stubbin> <args...>
  local home="$1" stubbin="$2"
  shift 2
  SNAPSHOT_FIXTURE="${TOPIC_TEST_SNAPSHOT:-$TMP_ROOT/snapshot.json}" \
    PATH="$stubbin:$PATH" FM_DATA_OVERRIDE="$home/data" \
    FM_TOPIC_SNAPSHOT="$stubbin/fmtb-snapshot" FM_TOPIC_NOW="$NOW" \
    "$TOPIC_BRIEF" "$@"
}

# --- tests -------------------------------------------------------------------

test_label_alias_project_membership() {
  local home stubbin json
  home=$(make_home member)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  json=$(run_topic "$home" "$stubbin" tf-mut --json) || fail "labeled run failed"
  local ready blocked landed flight decisions
  ready=$(jq -c '[.next_steps.ready[].id]' <<<"$json")
  blocked=$(jq -c '[.next_steps.blocked[].id]' <<<"$json")
  landed=$(jq -c '[.changed_since.landed[].id]' <<<"$json")
  flight=$(jq -c '[.in_flight[].id]' <<<"$json")
  decisions=$(jq -c '[.decisions_open[].id]' <<<"$json")
  [ "$ready" = '["t-lab","t-alias"]' ] || fail "ready membership wrong: $ready (t-lab by label, t-alias by alias, not t-topicless/t-out)"
  [ "$blocked" = '["t-proj"]' ] || fail "project-default membership wrong: $blocked"
  [ "$landed" = '["t-done"]' ] || fail "landed membership wrong: $landed"
  [ "$flight" = '["t-flight","mate/t-flight"]' ] || fail "second-mate in-flight membership wrong: $flight"
  [ "$decisions" = '["t-dec"]' ] || fail "decision membership wrong: $decisions"
  local prurl
  prurl=$(jq -r '[.changed_since.landed[] | select(.id == "t-done") | .pr_url][0]' <<<"$json")
  [ "$prurl" = "https://github.com/andrewesweet/treehouse/pull/42" ] || fail "recorded PR URL missing from landed row: $prurl"
  [ "$(jq -r '.in_flight[] | select(.id == "t-flight") | .pr_url' <<<"$json")" = "https://github.com/andrewesweet/treehouse/pull/77" ] \
    || fail "in-flight recorded PR array was not consumed"
  jq -e '.counts.landed == 1 and .counts.answered == 1 and (.changed_since.answered_decisions | map(.id)) == ["t-answ"] and (has("secondmates") | not)' <<<"$json" >/dev/null \
    || fail "answered calls or unfiltered secondmate context leaked into deliveries"
  pass "membership: label, alias, project default, second-mate rows, recorded PR"
}

test_decision_options_and_detail_enrichment() {
  local home stubbin json opts report holduntil
  home=$(make_home dec)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  json=$(run_topic "$home" "$stubbin" tf-mut --json) || fail "run failed"
  opts=$(jq -c '[.decisions_open[0].options[]]' <<<"$json")
  [ "$opts" = '["yolo on","yolo off","defer a week"]' ] || fail "options extraction wrong: $opts"
  local title
  title=$(jq -r '.decisions_open[0].title' <<<"$json")
  case "$title" in *"full title from detail"*) : ;; *) fail "detail show read not applied: $title" ;; esac
  report=$(jq -r '.decisions_open[0].report' <<<"$json")
  [ "$report" = "data/t-dec/report.md" ] || fail "decision report link wrong: $report"
  holduntil=$(jq -r '.decisions_open[0].hold_until' <<<"$json")
  [ "$holduntil" = "2026-11-15" ] || fail "hold_until wrong: $holduntil"
  pass "open decision: options marker parsed, detail enriches title/report/hold_until"
}

test_label_fallback() {
  local home stubbin json note ready
  home=$(make_home fallback)
  stubbin="$TMP_ROOT/stub-nolabels"
  make_stub_bin "$stubbin" nolabels
  json=$(run_topic "$home" "$stubbin" tf-mut --json) || fail "fallback run failed"
  [ "$(jq -r '.labels_available' <<<"$json")" = "false" ] || fail "fallback did not disclose labels_available false"
  note=$(jq -c '[.disclosures[] | select(test("does not support"))]' <<<"$json")
  [ -n "$note" ] && [ "$note" != "null" ] || fail "fallback disclosure missing: $(jq -c .disclosures <<<"$json")"
  ready=$(jq -c '[.next_steps.ready[].id]' <<<"$json")
  [ "$ready" = '["t-lab","t-topicless"]' ] || fail "fallback membership wrong: $ready (project default only; t-alias needs its label)"
  pass "label fallback: disclosed membership by default projects, exit 0"
}

test_window_default_since_and_recap() {
  local home stubbin w1 w2 w3
  home=$(make_home window)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  w1=$(run_topic "$home" "$stubbin" tf-mut --json | jq -c '.window') || fail "run failed"
  [ "$(jq -r '.source' <<<"$w1")" = "default-14d" ] || fail "default window source wrong: $w1"
  [ "$(jq -r '.since' <<<"$w1")" = "2026-10-18T09:00:00Z" ] || fail "default window since wrong: $w1"
  w2=$(run_topic "$home" "$stubbin" tf-mut --since 2026-10-23 --json | jq -c '.window') || fail "since run failed"
  { [ "$(jq -r '.source' <<<"$w2")" = "flag" ] && [ "$(jq -r '.since' <<<"$w2")" = "2026-10-23" ]; } \
    || fail "--since window wrong: $w2"
  # First HTML run writes history; the next run windows from it and recaps.
  run_topic "$home" "$stubbin" tf-mut --html "$home/brief-1.html" >/dev/null || fail "html run failed"
  [ -f "$home/data/topic-briefings/topic-tf-mut/T20261101T090000Z.json" ] || fail "history record not written"
  w3=$(FM_TOPIC_NOW=2026-11-08T09:00:00Z SNAPSHOT_FIXTURE="$TMP_ROOT/snapshot.json" \
      PATH="$stubbin:$PATH" FM_DATA_OVERRIDE="$home/data" \
      FM_TOPIC_SNAPSHOT="$stubbin/fmtb-snapshot" \
      "$TOPIC_BRIEF" tf-mut --json | jq -c '.window') || fail "second-window run failed"
  { [ "$(jq -r '.source' <<<"$w3")" = "previous-briefing" ] \
      && [ "$(jq -r '.since' <<<"$w3")" = "2026-11-01T09:00:00Z" ]; } \
    || fail "previous-briefing window wrong: $w3"
  pass "window: default 14d, --since flag, previous-briefing after history exists"
}

test_recap_and_history_read() {
  local home stubbin recap
  home=$(make_home recap)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  run_topic "$home" "$stubbin" tf-mut --html "$home/brief-1.html" >/dev/null || fail "first run failed"
  recap=$(FM_TOPIC_NOW=2026-11-08T09:00:00Z SNAPSHOT_FIXTURE="$TMP_ROOT/snapshot.json" \
    PATH="$stubbin:$PATH" FM_DATA_OVERRIDE="$home/data" \
    FM_TOPIC_SNAPSHOT="$stubbin/fmtb-snapshot" \
    "$TOPIC_BRIEF" tf-mut --json | jq -r '.recap.paragraph') || fail "recap run failed"
  case "$recap" in
    "Topic tf-mut briefing"*) : ;;
    *) fail "recap from history missing: $recap" ;;
  esac
  local explicit
  explicit=$(run_topic "$home" "$stubbin" tf-mut --since 2026-10-23 --json) || fail "explicit window run failed"
  jq -e --arg recap "$recap" '.recap.paragraph == $recap and .recap.generated == "2026-11-01T09:00:00Z" and .window.since == "2026-10-23"' <<<"$explicit" >/dev/null \
    || fail "explicit window erased recap: $explicit"
  pass "recap: previous summary survives an explicit window"
}

test_registry_errors() {
  local home badhome emptyhome out rc
  home=$(make_home regerr)
  out=$(run_topic "$home" "$TMP_ROOT/stub-labeled" nope --json 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "unknown topic must exit 2: rc=$rc out=$out"
  case "$out" in *"unknown topic: nope"*) : ;; *) fail "unknown-topic message not actionable: $out" ;; esac
  badhome="$TMP_ROOT/regbad"
  mkdir -p "$badhome/data"
  printf 'tf-mut treehouse :: broken\n' > "$badhome/data/topics.md"
  out=$(FM_DATA_OVERRIDE="$badhome/data" FM_TOPIC_NOW="$NOW" "$TOPIC_BRIEF" tf-mut --json 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "malformed registry must exit 2: rc=$rc out=$out"
  case "$out" in *"line 1"*) : ;; *) fail "malformed registry error lacks line number: $out" ;; esac
  emptyhome="$TMP_ROOT/regnone"
  mkdir -p "$emptyhome/data"
  out=$(FM_DATA_OVERRIDE="$emptyhome/data" FM_TOPIC_NOW="$NOW" "$TOPIC_BRIEF" tf-mut --json 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "missing registry must exit 2: rc=$rc out=$out"
  case "$out" in *"no topics are registered"*) : ;; *) fail "missing registry error wrong: $out" ;; esac
  pass "registry errors: unknown topic, malformed line, absent file all actionable"
}

test_registry_optional_fields() {
  local home json
  home="$TMP_ROOT/regopt"
  mkdir -p "$home/data"
  # A topic without aliases or projects is legal: membership then relies on
  # labels alone and the registry line must still resolve (regression: a
  # record with an empty projects field used to vanish in the registry parse).
  printf -- '- solo
- tf-mut | aliases: mut\n' > "$home/data/topics.md"
  json=$(SNAPSHOT_FIXTURE="$TMP_ROOT/snapshot.json" FM_DATA_OVERRIDE="$home/data" FM_TOPIC_NOW="$NOW" \
    PATH="$TMP_ROOT/stub-labeled:$PATH" \
    FM_TOPIC_SNAPSHOT="$TMP_ROOT/stub-labeled/fmtb-snapshot" \
    "$TOPIC_BRIEF" mut --json) || fail "alias-only topic run failed"
  [ "$(jq -r '.topic.name' <<<"$json")" = "tf-mut" ] || fail "topic without projects not resolved"
  local ready
  ready=$(jq -c '[.next_steps.ready[].id]' <<<"$json")
  [ "$ready" = '["t-lab","t-alias"]' ] || fail "label-only membership wrong: $ready"
  pass "registry: alias-only topics and topics without projects resolve"
}

test_json_and_summary_are_exclusive() {
  local home stubbin jsonout
  home=$(make_home exclusive)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  jsonout=$(run_topic "$home" "$stubbin" tf-mut --json) || fail "json run failed"
  case "$jsonout" in
    '{'*'"schema": "fm-topic-brief.v1"'*) : ;;
    *) fail "--json stdout is not pure model JSON" ;;
  esac
  case "$jsonout" in *'"topic: tf-mut"'*) fail "--json output mixed the chat summary into stdout" ;; esac
  pass "--json prints the model only; chat summary reserved for the no-flag path"
}

test_html_self_containment_and_answers_line() {
  local home stubbin html
  home=$(make_home html)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  run_topic "$home" "$stubbin" tf-mut --html "$home/brief.html" >/dev/null || fail "html run failed"
  html=$(cat "$home/brief.html")
  case "$html" in
    "<!doctype html>"*) : ;;
    *) fail "HTML missing doctype" ;;
  esac
  printf '%s' "$html" | grep -q 'name="viewport" content="width=device-width, initial-scale=1"' \
    || fail "HTML missing mobile viewport meta"
  [ "$(printf '%s\n' "$html" | grep -cE 'src="http|<link[^>]*href="http')" = 0 ] \
    || fail "HTML references an external resource"
  printf '%s' "$html" | grep -q '<svg' || fail "HTML missing inline SVG timeline"
  printf '%s' "$html" | grep -q '<noscript>' || fail "HTML missing noscript answers documentation"
  printf '%s' "$html" | grep -q 'TOPIC-ANSWERS v1 | topic=tf-mut | answered=0/1</pre>' \
    || fail "HTML answers line initial text wrong"
  # The decision options carry their recorded text; freeform textarea exists.
  printf '%s' "$html" | grep -q 'value="yolo on"' || fail "HTML option values must carry recorded text"
  printf '%s' "$html" | grep -q 'data-decision="0"> yolo on</label>' || fail "HTML option labels missing"
  printf '%s' "$html" | grep -q 'reconcile' || fail "HTML reconcile option missing"
  pass "HTML: self-contained, mobile viewport, inline SVG, noscript answers doc, answers line"
}

make_board_stub() {
  local stubbin="$1" capture="$TMP_ROOT/captured-board.json"
  cat > "$stubbin/fm-bearings-board" <<EOF
#!/usr/bin/env bash
# Test seam for FM_TOPIC_BOARD_CMD: capture the composed payload verbatim.
printf '%s\n' "\$*" >> "$stubbin/board-calls.log"
[ "\${1:-}" = build ] && cp "\$2" "$capture" && exit 0
exit 9
EOF
  chmod +x "$stubbin/fm-bearings-board"
}

test_board_payload_shape() {
  local home stubbin capture opts
  home=$(make_home board)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  capture="$TMP_ROOT/captured-board.json"
  make_board_stub "$stubbin"
  SNAPSHOT_FIXTURE="$TMP_ROOT/snapshot.json" PATH="$stubbin:$PATH" \
    FM_DATA_OVERRIDE="$home/data" FM_TOPIC_SNAPSHOT="$stubbin/fmtb-snapshot" \
    FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" FM_TOPIC_NOW="$NOW" \
    "$TOPIC_BRIEF" tf-mut --board >/dev/null || fail "--board with stubbed board command failed"
  [ -f "$capture" ] || fail "board command was not invoked with a payload"
  opts=$(jq -c '[.captains_call[0].options[].value]' "$capture")
  [ "$opts" = '["option-0-yolo-on","option-1-yolo-off","option-2-defer-a-week"]' ] || fail "board option values must be distinct slugs: $opts"
  local labels
  labels=$(jq -c '[.captains_call[0].options[].label]' "$capture")
  [ "$labels" = '["yolo on","yolo off","defer a week"]' ] || fail "board option labels lost recorded text: $labels"
  jq -e '(.schema == "fm-bearings-board.v1") and (.home | length > 0) and (.captains_call | type == "array")
      and (.underway | type == "array") and (.landed | type == "array") and (.charted | type == "array")
      and ([.captains_call[] | has("key") and (.key | test("^[A-Za-z0-9._-]{1,128}$"))] | all)
      and ([.underway[] | has("repo")] | all) and ([.landed[] | has("repo") and has("owner")] | all)
      and ([.charted[] | has("repo") and (.dispatchable | type == "boolean")] | all)' \
    "$capture" >/dev/null || fail "board payload violates the fm-bearings-board.v1 shape"
  local mateflight
  mateflight=$(jq -c '[.underway[].id]' "$capture")
  [ "$mateflight" = '["t-flight","mate/t-flight"]' ] || fail "board underway should carry only topic member rows: $mateflight"
  pass "board payload: distinct values with recorded labels, topic-scoped rows, shape contract"
}


test_secondmate_membership_all_surfaces() {
  local home stubbin placement json
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  for placement in local remote; do
    home=$(make_home "mate-$placement")
    write_toon > "$home/mate.toon" <<'EOF'
[
  {"id":"t-flight","state":"in_flight","kind":"ship","repo":"treehouse","labels":["topic:crew-wiki"],"title":"Unrelated child"},
  {"id":"t-nowhere","state":"in_flight","kind":"ship","repo":"-","labels":["topic:mut"],"title":"Labelled child without repo","created":"2026-10-24"},
  {"id":"t-match","state":"in_flight","kind":"ship","repo":"other-repo","labels":["topic:tf-mut"],"title":"Labelled child outside defaults","created":"2026-10-24"},
  {"id":"t-dec2","state":"queued","kind":"ship","repo":"other-repo","labels":["topic:mut"],"title":"Mate captain call","hold_kind":"captain","held":"no","hold_until":"2026-10-31","hold_reason":"Question: which mate path? options: continue | wait","created":"2026-10-24"},
  {"id":"t-done2","state":"done","kind":"scout","repo":"treehouse","labels":[],"title":"Mate report","closed":"2026-10-29","links":["report:data/t-done2/report.md"]},
  {"id":"t-answ2","state":"done","kind":"captain","repo":"treehouse","labels":[],"title":"Mate answer","closed":"2026-10-29"},
  {"id":"t-ready","state":"queued","repo":"treehouse","labels":[],"title":"Mate next step","blocked_by":["t-done2"]}
]
EOF
    jq '.in_flight += [{id:"mate/t-match",kind:"ship",state:"working",repo:"other-repo",name:"Labelled child outside defaults",doing:"work"}]' \
      "$TMP_ROOT/snapshot.json" > "$home/snapshot.json"
    if [ "$placement" = remote ]; then
      printf -- '- mate - Remote fixture (host: fixturehost; root: %s; home: %s/mate; scope: tests; projects: treehouse; added 2026-10-01)\n' "$ROOT" "$home" > "$home/data/secondmates.md"
      cat > "$home/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s' "${!#}" | base64 -d | tr '\0' '\n' > "$TOPIC_ROUTE_LOG"
[ "$(sed -n '1p' "$TOPIC_ROUTE_LOG")" = fm-tasks-axi.sh ] || exit 9
case "$(sed -n '2p' "$TOPIC_ROUTE_LOG")" in
  list) cat "$TOPIC_MATE_FIXTURE" ;;
  show) exit 1 ;;
  *) exit 9 ;;
esac
SH
      chmod +x "$home/ssh"
    fi
    json=$(TOPIC_MATE_FIXTURE="$home/mate.toon" TOPIC_TEST_SNAPSHOT="$home/snapshot.json" \
      FM_SSH_BIN="$home/ssh" TOPIC_ROUTE_LOG="$home/remote-call" \
      run_topic "$home" "$stubbin" tf-mut --json) || fail "$placement mate run failed"
    jq -e '
      [.in_flight[].id] == ["t-flight","mate/t-nowhere","mate/t-match"]
      and [.decisions_open[].id] == ["t-dec","mate/t-dec2"]
      and [.changed_since.landed[].id] == ["t-done","mate/t-done2"]
      and [.changed_since.answered_decisions[].id] == ["t-answ","mate/t-answ2"]
      and [.next_steps.ready[].id] == ["t-lab","t-alias","mate/t-ready"]
      and any(.timeline[]; .id == "mate/t-done2" and .kind == "landed")
      and any(.timeline[]; .id == "mate/t-answ2" and .kind == "answered")
      and .counts.landed == 2 and .counts.answered == 2 and .counts.decisions == 2
    ' <<<"$json" >/dev/null || fail "$placement membership differs across surfaces: $json"
    [ "$placement" != remote ] || [ -s "$home/remote-call" ] || fail "remote tasks read was bypassed"
  done
  pass "local and remote mates share label, alias, default-project and dependency rules across every collection"
}

test_deferred_calls_and_resolved_dependencies() {
  local home stubbin json
  home=$(make_home deferred)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  sed 's/,yes,captain,2026-11-15,/,no,captain,2026-10-31,/' "$TMP_ROOT/list-labels.toon" > "$home/main.toon"
  sed 's/held: yes/held: no/; s/2026-11-15/2026-10-31/' "$TMP_ROOT/show-t-dec.toon" > "$home/detail.toon"
  sed '/^help\[/,$d; s/^count: 9$/count: 10/; s/^tasks\[9\]/tasks[10]/' "$home/main.toon" > "$home/rows.toon"
  cat >> "$home/rows.toon" <<'EOF'
  t-unblocked,queued,ship,treehouse,Resolved dependency,none,t-done,2026-10-30,"-",no,"-","-",none,"-"
EOF
  json=$(TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_DETAIL_FIXTURE="$home/detail.toon" \
    run_topic "$home" "$stubbin" tf-mut --json) || fail "deferred run failed"
  jq -e '
    [.decisions_open[].id] == ["t-dec"]
    and (.decisions_open[0].title | contains("full title from detail"))
    and any(.next_steps.ready[]; .id == "t-unblocked")
    and all(.next_steps.ready[], .next_steps.blocked[]; .id != "t-dec")
    and [.next_steps.blocked[].id] == ["t-proj"]
  ' <<<"$json" >/dev/null || fail "captain or dependency state misclassified: $json"
  make_board_stub "$stubbin"
  TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_DETAIL_FIXTURE="$home/detail.toon" FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" \
    run_topic "$home" "$stubbin" tf-mut --board >/dev/null || fail "deferred board failed"
  jq -e 'any(.charted[]; .id == "t-unblocked" and .dispatchable) and all(.charted[]; .id != "t-dec") and [.landed[].id] == ["t-done"]' \
    "$TMP_ROOT/captured-board.json" >/dev/null || fail "board reintroduced blockers or counted a captain answer as a delivery"
  pass "dated captain calls remain enriched decisions; completed dependencies stop blocking"
}

test_external_holds_remain_blocked_in_every_home_and_output() {
  local home stubbin placement json chat
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  make_board_stub "$stubbin"
  for placement in local remote; do
    home=$(make_home "external-$placement")
    write_toon > "$home/rows.toon" <<'EOF'
[
  {"id":"external-queue","kind":"ship","state":"queued","repo":"treehouse","created":"2026-10-01","title":"Vendor gate","held":"yes","hold_kind":"external","hold_until":"2026-11-15","hold_reason":"Waiting on vendor <approval>","blocked_by":["done","ready"]},
  {"id":"external-flight","kind":"ship","state":"in_flight","repo":"other-repo","labels":["topic:tf-mut"],"created":"2026-10-01","title":"Build gate","held":true,"hold_kind":"external","hold_reason":"Waiting on build"},
  {"id":"external-observe","kind":"observe","state":"in_flight","repo":"-","labels":["topic:mut"],"created":"2026-10-01","title":"Rollout observation","held":"yes","hold_kind":"external","hold_until":"2026-11-20","hold_reason":"Watching rollout"},
  {"id":"dependency","state":"queued","repo":"treehouse","created":"2026-10-01","title":"Dependency gate","blocked_by":["done","ready"]},
  {"id":"ready","state":"queued","repo":"treehouse","created":"2026-10-01","title":"Ready work"},
  {"id":"expired","state":"queued","repo":"treehouse","created":"2026-10-01","title":"Expired wait","held":"no","hold_kind":"external","hold_until":"2026-10-31","hold_reason":"Old wait","blocked_by":["done"]},
  {"id":"done","state":"done","repo":"treehouse","created":"2026-10-01","closed":"2026-10-02","title":"Completed wait","held":"yes","hold_kind":"external","hold_reason":"Old wait"},
  {"id":"unrelated","state":"queued","repo":"treehouse","labels":["topic:crew-wiki"],"created":"2026-10-01","title":"Other topic","held":"yes","hold_kind":"external","hold_reason":"Other wait"},
  {"id":"t-dec","state":"queued","repo":"treehouse","created":"2026-10-01","title":"Captain call","held":"yes","hold_kind":"captain","hold_reason":"Question: choose?"}
]
EOF
    printf '{"in_flight":[],"landed":[],"recorded_prs":[]}\n' > "$home/snapshot.json"
    if [ "$placement" = remote ]; then
      printf -- '- mate - Remote fixture (host: fixturehost; root: %s; home: %s/mate; scope: tests; projects: treehouse; added 2026-10-01)\n' "$ROOT" "$home" > "$home/data/secondmates.md"
      cat > "$home/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s' "${!#}" | base64 -d | tr '\0' '\n' > "$TOPIC_ROUTE_LOG"
case "$(sed -n '2p' "$TOPIC_ROUTE_LOG")" in
  list) cat "$TOPIC_MATE_FIXTURE" ;;
  show) cat "$TOPIC_DETAIL_FIXTURE" ;;
  *) exit 9 ;;
esac
SH
      chmod +x "$home/ssh"
    fi
    json=$(TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_MATE_FIXTURE="$home/rows.toon" \
      TOPIC_DETAIL_FIXTURE="$TMP_ROOT/show-t-dec.toon" TOPIC_TEST_SNAPSHOT="$home/snapshot.json" \
      FM_SSH_BIN="$home/ssh" TOPIC_ROUTE_LOG="$home/remote-call" \
      run_topic "$home" "$stubbin" tf-mut --json) || fail "$placement external holds model failed"
    jq -e '
      .counts.blocked == 8 and .counts.ready == 4 and .counts.decisions == 2 and .counts.new_rows == 0
      and [.decisions_open[].id] == ["t-dec","mate/t-dec"]
      and [.next_steps.ready[].id] == ["ready","expired","mate/ready","mate/expired"]
      and [.next_steps.blocked[].id] == ["external-queue","external-flight","external-observe","dependency","mate/external-queue","mate/external-flight","mate/external-observe","mate/dependency"]
      and ([.next_steps.blocked[] | select(.id == "external-queue" or .id == "mate/external-queue") | {hold_reason,hold_until}] == [{hold_reason:"Waiting on vendor <approval>",hold_until:"2026-11-15"},{hold_reason:"Waiting on vendor <approval>",hold_until:"2026-11-15"}])
      and any(.next_steps.blocked[]; .id == "external-queue" and .blocked_by == ["ready"] and .reason == "external hold until 2026-11-15: Waiting on vendor <approval>; blocked by ready")
      and any(.next_steps.blocked[]; .id == "mate/external-queue" and .owner == "mate" and .blocked_by == ["mate/ready"] and .reason == "external hold until 2026-11-15: Waiting on vendor <approval>; blocked by mate/ready")
      and ([.next_steps.blocked[] | select(.id == "external-flight" or .id == "mate/external-flight") | .reason] == ["external hold: Waiting on build","external hold: Waiting on build"])
      and ([.next_steps.blocked[] | select(.id == "external-observe" or .id == "mate/external-observe") | .reason] == ["external hold until 2026-11-20: Watching rollout","external hold until 2026-11-20: Watching rollout"])
      and any(.next_steps.blocked[]; .id == "dependency" and .reason == "blocked by ready")
    ' <<<"$json" >/dev/null || fail "$placement external work vanished, became dispatchable or lost its recorded reason/date: $json"
    chat=$(TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_MATE_FIXTURE="$home/rows.toon" \
      TOPIC_DETAIL_FIXTURE="$TMP_ROOT/show-t-dec.toon" TOPIC_TEST_SNAPSHOT="$home/snapshot.json" \
      FM_SSH_BIN="$home/ssh" TOPIC_ROUTE_LOG="$home/remote-call" \
      FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" \
      run_topic "$home" "$stubbin" tf-mut --html "$home/brief.html" --board) || fail "$placement external hold outputs failed"
    case "$chat" in *'next steps: 4 ready, 8 blocked'*) : ;; *) fail "chat lost external holds: $chat" ;; esac
    jq -e '([.charted[] | select(.dispatchable | not)] | length) == 8
      and any(.charted[]; .id == "external-queue" and .reason == "external hold until 2026-11-15: Waiting on vendor <approval>; blocked by ready")
      and any(.charted[]; .id == "mate/external-observe" and .owner == "mate" and .reason == "external hold until 2026-11-20: Watching rollout")' \
      "$TMP_ROOT/captured-board.json" >/dev/null || fail "board changed blocked classification or reasons"
    python3 - "$home/brief.html" <<'PY' || fail "HTML lost held work or its recorded reason/date"
from html.parser import HTMLParser
import sys

class Text(HTMLParser):
    def handle_data(self, data):
        self.parts.append(data)

page = Text()
page.parts = []
with open(sys.argv[1]) as source:
    page.feed(source.read())
text = " ".join(page.parts)
for prefix in ("", "mate/"):
    for expected in (
        "external-queue · external hold until 2026-11-15: Waiting on vendor <approval>; blocked by " + prefix + "ready",
        "external-flight · external hold: Waiting on build",
        "external-observe · external hold until 2026-11-20: Watching rollout",
        "dependency · blocked by " + prefix + "ready",
    ):
        assert prefix + expected in text, (prefix, expected)
PY
  done
  pass "queued and in-flight external holds, including observations, stay blocked with recorded reasons/dates in main and local/remote mate outputs"
}

test_chat_details_and_read_only_modes() {
  local home stubbin out
  home=$(make_home chat)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  out=$(run_topic "$home" "$stubbin" tf-mut) || fail "chat run failed"
  case "$out" in
    *'decision: t-dec Question: which merge posture for topic briefings? options: yolo on | yolo off | defer a week'*) : ;;
    *) fail "chat lacks recorded question/options: $out" ;;
  esac
  case "$out" in *'landed: t-done Landed member row with PR https://github.com/andrewesweet/treehouse/pull/42'*) : ;; *) fail "chat lacks landed item/PR: $out" ;; esac
  case "$out" in *'in flight: 2 - Main child in flight; Second-mate child in flight'*) : ;; *) fail "chat lacks in-flight names: $out" ;; esac
  case "$out" in *'timeline:'*) fail "chat contains timeline" ;; esac
  run_topic "$home" "$stubbin" tf-mut --json >/dev/null || fail "json run failed"
  make_board_stub "$stubbin"
  FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" run_topic "$home" "$stubbin" tf-mut --board >/dev/null || fail "board run failed"
  [ ! -e "$home/data/topic-briefings" ] || fail "read-only modes wrote history"
  pass "chat carries recorded details; chat, JSON and board leave history untouched"
}

test_registry_name_alias_collisions() {
  local home out query rc
  home=$(make_home alias-collision)
  printf -- '- alpha | aliases: beta\n- beta\n' > "$home/data/topics.md"
  for query in alpha beta; do
    out=$(run_topic "$home" "$TMP_ROOT/stub-labeled" "$query" --json 2>&1) && rc=0 || rc=$?
    [ "$rc" = 2 ] || fail "colliding name/alias accepted for $query"
    case "$out" in *'duplicate topic name or alias: beta'*) : ;; *) fail "collision diagnostic missing: $out" ;; esac
  done
  pass "name/alias collisions fail before either resolution path"
}

test_portable_dates_and_calendar_validation() {
  local home stubbin real_date json out rc
  home=$(make_home portable-date)
  stubbin="$TMP_ROOT/stub-portable"
  make_stub_bin "$stubbin" labeled
  real_date=$(command -v date)
  cat > "$stubbin/date" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do [ "\$arg" != -d ] || exit 99; done
exec "$real_date" "\$@"
EOF
  chmod +x "$stubbin/date"
  json=$(run_topic "$home" "$stubbin" tf-mut --json) || fail "default needs GNU date"
  [ "$(jq -r '.window.since' <<<"$json")" = 2026-10-18T09:00:00Z ] || fail "default window drifted"
  run_topic "$home" "$stubbin" tf-mut --since 2024-02-29 --json >/dev/null || fail "valid leap day rejected"
  out=$(run_topic "$home" "$stubbin" tf-mut --since 2026-02-30 --json 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "impossible calendar date accepted: $out"
  pass "default and explicit windows need no GNU date; impossible dates fail"
}

test_publication_failure_preserves_history_and_empty_states() {
  local home stubbin out rc before html
  home=$(make_home publication)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  out=$(run_topic "$home" "$stubbin" tf-mut --html "$home" 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] && [ ! -e "$home/data/topic-briefings" ] || fail "failed publication advanced history: $out"
  if printf '%s\n' "$out" | grep -q '^briefing: '; then fail "failed publication reported success"; fi
  printf -- '- empty\n' > "$home/data/topics.md"
  run_topic "$home" "$stubbin" empty --html "$home/empty.html" >/dev/null || fail "empty html failed"
  html=$(cat "$home/empty.html")
  for expected in 'Nothing landed in this window.' 'Nothing in flight for this topic.' 'No open decisions for this topic.' 'Nothing ready.' 'No events in this window.'; do
    case "$html" in *"$expected"*) : ;; *) fail "missing empty state: $expected" ;; esac
  done
  case "$html" in *'id="recap"'*) fail "first briefing has an empty recap" ;; esac
  before=$(cat "$home/data/topic-briefings/topic-empty/T20261101T090000Z.json")
  run_topic "$home" "$stubbin" empty --html "$home" >/dev/null 2>&1 && fail "directory output succeeded"
  [ "$(cat "$home/data/topic-briefings/topic-empty/T20261101T090000Z.json")" = "$before" ] || fail "failed publication changed existing history"
  pass "failed HTML publication preserves history; empty briefs show every empty state"
}

test_coverage_disclosures_in_every_mode() {
  local home stubbin json out html
  home=$(make_home coverage)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  jq '.secondmates = [{id:"offline",state:"unknown",freshness:"unavailable",reason:"ledger missing"},{id:"cached",state:"active_child_work",freshness:"fresh",provenance:"structured-home-cache",reason:"cached ledger"}]
    | .omitted = [{surface:"secondmate children truncated",reveal:"raise bound"}]' "$TMP_ROOT/snapshot.json" > "$home/snapshot.json"
  json=$(TOPIC_TEST_SNAPSHOT="$home/snapshot.json" run_topic "$home" "$stubbin" tf-mut --json) || fail "coverage model failed"
  jq -e 'any(.disclosures[]; contains("offline") and contains("ledger missing")) and any(.disclosures[]; contains("cached")) and any(.disclosures[]; contains("truncated"))' <<<"$json" >/dev/null || fail "coverage lost: $json"
  make_board_stub "$stubbin"
  out=$(TOPIC_TEST_SNAPSHOT="$home/snapshot.json" FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" \
    run_topic "$home" "$stubbin" tf-mut --html "$home/coverage.html" --board) || fail "coverage outputs failed"
  html=$(cat "$home/coverage.html")
  for expected in offline cached truncated; do
    case "$out" in *"$expected"*) : ;; *) fail "chat lost $expected" ;; esac
    case "$html" in *"$expected"*) : ;; *) fail "html lost $expected" ;; esac
  done
  pass "unavailable, cached and truncated coverage survives JSON, chat and HTML"
}

test_complete_distinct_board_options() {
  local home stubbin json capture
  home=$(make_home options)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  jq -n '["A/B", "A-B", "reconcile", "four", "five", "six", ("long " + ("condition " * 20) + "keep this suffix")]' > "$home/options.json"
  jq '[{id:"t-dec",hold_kind:"captain",state:"queued",title:"Recorded choice",hold_reason:("Question: choose? options: " + join(" | "))}]' "$home/options.json" | write_toon detail > "$home/detail.toon"
  json=$(TOPIC_DETAIL_FIXTURE="$home/detail.toon" run_topic "$home" "$stubbin" tf-mut --json) || fail "options model failed"
  jq -e --slurpfile expected "$home/options.json" '.decisions_open[0].options == $expected[0]' <<<"$json" >/dev/null || fail "options truncated"
  make_board_stub "$stubbin"
  TOPIC_DETAIL_FIXTURE="$home/detail.toon" FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" \
    run_topic "$home" "$stubbin" tf-mut --board >/dev/null || fail "options board failed"
  capture="$TMP_ROOT/captured-board.json"
  jq -e --slurpfile expected "$home/options.json" '
    [.captains_call[0].options[].label] == ($expected[0] | map(select(. != "reconcile")))
    and ([.captains_call[0].options[].value] | length == (unique | length) and all(.[]; . != "reconcile" and test("^[A-Za-z0-9._-]{1,128}$")))
  ' "$capture" >/dev/null || fail "options collide, reserve reconcile or lose meaning"
  pass "recorded options stay whole; the board owns the reserved reconcile choice"
}

test_enriched_decisions_recheck_each_home_state() {
  local home stubbin owner outcome json chat live_id expected
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  make_board_stub "$stubbin"
  for owner in main mate; do
    for outcome in done released; do
      home=$(make_home "enriched-$owner-$outcome")
      write_toon > "$home/list.toon" <<'EOF'
[{"id":"t-dec","state":"queued","kind":"ship","repo":"treehouse","title":"List call","hold_kind":"captain","held":"yes","hold_reason":"Question: old list question?"}]
EOF
      write_toon detail > "$home/live.toon" <<'EOF'
[{"id":"t-dec","state":"in_flight","kind":"ship","repo":"treehouse","title":"Still open","hold_kind":"captain","held":"no","hold_until":"2026-10-01","hold_reason":"Question: surviving call? options: approve | wait"}]
EOF
      jq -n --arg outcome "$outcome" '[{id:"t-dec",state:(if $outcome == "done" then "done" else "in_flight" end),kind:"ship",repo:"treehouse",title:"Obsolete call",hold_kind:(if $outcome == "done" then "captain" else "-" end),held:"no",hold_reason:"Question: obsolete call?"}]' \
        | write_toon detail > "$home/obsolete.toon"
      local main_detail="$home/live.toon" mate_detail="$home/obsolete.toon"
      live_id=t-dec
      if [ "$owner" = main ]; then
        main_detail="$home/obsolete.toon"
        mate_detail="$home/live.toon"
        live_id=mate/t-dec
      fi
      json=$(TOPIC_MAIN_FIXTURE="$home/list.toon" TOPIC_MATE_FIXTURE="$home/list.toon" \
        TOPIC_DETAIL_FIXTURE="$main_detail" TOPIC_MATE_DETAIL_FIXTURE="$mate_detail" \
        run_topic "$home" "$stubbin" tf-mut --json) || fail "enriched $owner $outcome model failed"
      jq -e --arg id "$live_id" '.counts.decisions == 1 and [.decisions_open[].id] == [$id]
        and .decisions_open[0].hold_reason == "Question: surviving call? options: approve | wait"
        and (.recap_next | contains("1 decision(s) open"))' <<<"$json" >/dev/null || fail "enriched $owner $outcome eligibility was lost: $json"
      chat=$(TOPIC_MAIN_FIXTURE="$home/list.toon" TOPIC_MATE_FIXTURE="$home/list.toon" \
        TOPIC_DETAIL_FIXTURE="$main_detail" TOPIC_MATE_DETAIL_FIXTURE="$mate_detail" \
        FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" \
        run_topic "$home" "$stubbin" tf-mut --html "$home/brief.html" --board) || fail "enriched $owner $outcome outputs failed"
      expected="decision: $live_id Question: surviving call? options: approve | wait"
      [ "$(printf '%s\n' "$chat" | sed -n '/^decision: /p')" = "$expected" ] || fail "chat retained an obsolete $owner $outcome call: $chat"
      jq -e --arg id "$live_id" '[.captains_call[].key] == [$id]' "$TMP_ROOT/captured-board.json" >/dev/null || fail "board retained an obsolete $owner $outcome call"
      python3 - "$home/brief.html" "$live_id" <<'PY' || fail "HTML retained an obsolete call"
from html.parser import HTMLParser
import sys

class Decisions(HTMLParser):
    def __init__(self):
        super().__init__()
        self.depth = 0
        self.text = []
        self.cards = []
    def handle_starttag(self, tag, attrs):
        if tag == "div":
            if self.depth:
                self.depth += 1
            elif dict(attrs).get("class") == "card decision":
                self.depth = 1
                self.text = []
    def handle_endtag(self, tag):
        if tag == "div" and self.depth:
            self.depth -= 1
            if not self.depth:
                self.cards.append(" ".join(self.text))
    def handle_data(self, data):
        if self.depth:
            self.text.append(data)

page = Decisions()
with open(sys.argv[1]) as source:
    page.feed(source.read())
assert len(page.cards) == 1, page.cards
assert sys.argv[2] in page.cards[0] and "surviving call?" in page.cards[0], page.cards
assert "obsolete call?" not in page.cards[0], page.cards
PY
      jq -e '.counts.decisions == 1 and (.recap | contains("1 decision(s) open"))' \
        "$home/data/topic-briefings/topic-tf-mut/T20261101T090000Z.json" >/dev/null || fail "history recap retained an obsolete call"
    done
  done
  pass "each home's answered or released detail disappears from decisions, recap, counts, chat, HTML and board; expired live holds remain"
}

test_latest_offline_answer_wins() {
  local home stubbin
  home=$(make_home latest-answer)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  run_topic "$home" "$stubbin" tf-mut --html "$home/answers.html" >/dev/null || fail "answers html failed"
  node "$ROOT/tests/assets/topic-answers-harness.mjs" "$home/answers.html" || fail "latest displayed answer was not exported"
  pass "typing replaces radio selection; selecting replaces text; copy exports the latest answer"
}

test_board_preserves_work_modes_dates_and_empty_defaults() {
  local home stubbin json
  home=$(make_home board-contract)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  make_board_stub "$stubbin"
  write_toon > "$home/rows.toon" <<'EOF'
[
  {"id":"t-dec","kind":"ship","state":"in_flight","repo":"treehouse","title":"Merge gate","hold_kind":"captain","held":"yes","created":"2026-10-20","hold_reason":"Question: approve merge? options: approve | wait"},
  {"id":"t-question","kind":"captain","state":"queued","repo":"treehouse","title":"Question","hold_kind":"captain","held":"yes","hold_reason":"Question: choose?"},
  {"id":"t-old","state":"queued","repo":"treehouse","title":"Older ready","created":"2026-10-20"},
  {"id":"t-new","state":"queued","repo":"treehouse","title":"Newer blocked","created":"2026-10-30","blocked_by":["t-old"]},
  {"id":"t-flight","kind":"ship","state":"in_flight","repo":"treehouse","title":"Working"},
  {"id":"t-done","kind":"ship","state":"done","repo":"treehouse","title":"","closed":"2026-10-28"}
]
EOF
  write_toon detail > "$home/detail.toon" <<'EOF'
[{"id":"t-dec","kind":"ship","state":"in_flight","repo":"treehouse","title":"Merge gate","hold_kind":"captain","held":"yes","hold_reason":"Question: approve merge? options: approve | wait"}]
EOF
  jq '(.in_flight[] | select(.id == "t-flight")) |= (.name = "" | .doing = "")' "$TMP_ROOT/snapshot.json" > "$home/snapshot.json"
  json=$(TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_DETAIL_FIXTURE="$home/detail.toon" TOPIC_TEST_SNAPSHOT="$home/snapshot.json" \
    run_topic "$home" "$stubbin" tf-mut --json) || fail "board contract model failed"
  jq -e '
    any(.decisions_open[]; .id == "t-dec" and .kind == "ship" and .state == "in_flight" and .close == "release")
    and any(.decisions_open[]; .id == "t-question" and .close == "done")
  ' <<<"$json" >/dev/null || fail "work/question completion modes lost: $json"
  TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_DETAIL_FIXTURE="$home/detail.toon" TOPIC_TEST_SNAPSHOT="$home/snapshot.json" \
    FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" run_topic "$home" "$stubbin" tf-mut --board >/dev/null || fail "empty board defaults failed"
  jq -e '
    any(.captains_call[]; .key == "t-dec" and .close == "release")
    and any(.captains_call[]; .key == "t-question" and .close == "done")
    and any(.charted[]; .id == "t-old" and .filed == "2026-10-20")
    and any(.charted[]; .id == "t-new" and .filed == "2026-10-30")
    and any(.underway[]; .id == "t-flight" and .name == "t-flight" and .doing == "in_flight")
    and any(.landed[]; .id == "t-done" and .what == "t-done")
  ' "$TMP_ROOT/captured-board.json" >/dev/null || fail "mode, filed date or row defaults lost"
  pass "board projection preserves completion modes, both filed dates and empty scalar defaults"
}

test_snapshot_delivery_artifacts_reach_every_output() {
  local home stubbin json out html
  home=$(make_home artifacts)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  make_board_stub "$stubbin"
  sed 's@"pr:https://github.com/andrewesweet/treehouse/pull/42"@none@' "$TMP_ROOT/list-labels.toon" > "$home/rows.toon"
  write_toon > "$home/mate.toon" <<'EOF'
[{"id":"t-done2","kind":"scout","state":"done","repo":"treehouse","title":"Recorded report","closed":"2026-10-29","links":[]}]
EOF
  jq '(.landed[] | select(.id == "t-done")).artifact = "https://github.com/andrewesweet/treehouse/pull/42"' "$TMP_ROOT/snapshot.json" > "$home/snapshot.json"
  json=$(TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_MATE_FIXTURE="$home/mate.toon" TOPIC_TEST_SNAPSHOT="$home/snapshot.json" \
    run_topic "$home" "$stubbin" tf-mut --json) || fail "artifact model failed"
  jq -e '[.changed_since.landed[].artifact] == ["https://github.com/andrewesweet/treehouse/pull/42","data/t-done2/report.md"]' <<<"$json" >/dev/null || fail "snapshot artifacts lost: $json"
  out=$(TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_MATE_FIXTURE="$home/mate.toon" TOPIC_TEST_SNAPSHOT="$home/snapshot.json" \
    FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" run_topic "$home" "$stubbin" tf-mut --html "$home/artifacts.html" --board) || fail "artifact outputs failed"
  html=$(cat "$home/artifacts.html")
  for artifact in https://github.com/andrewesweet/treehouse/pull/42 data/t-done2/report.md; do
    case "$out" in *"$artifact"*) : ;; *) fail "chat lost $artifact" ;; esac
    case "$html" in *"$artifact"*) : ;; *) fail "HTML lost $artifact" ;; esac
  done
  jq -e '[.landed[].artifact] == ["https://github.com/andrewesweet/treehouse/pull/42","data/t-done2/report.md"]' "$TMP_ROOT/captured-board.json" >/dev/null || fail "board projection lost artifacts"
  pass "snapshot-only PR and report artifacts survive JSON, HTML, chat and board projection"
}

test_all_and_only_topic_decisions_are_enriched() {
  local home stubbin json shown
  home=$(make_home all-details)
  stubbin="$TMP_ROOT/stub-all-details"
  make_stub_bin "$stubbin" labeled
  jq -n '[range(0;25) | {id:("other-" + tostring),state:"queued",kind:"captain",repo:"other-repo",labels:["topic:crew-wiki"],hold_kind:"captain",hold_reason:"Other topic"}]
    + [range(0;23) | {id:("member-" + tostring),state:"queued",kind:"captain",repo:"treehouse",labels:["topic:mut"],hold_kind:"captain",hold_reason:"Short list reason"}]' > "$home/rows.json"
  write_toon < "$home/rows.json" > "$home/rows.toon"
  cat > "$stubbin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) cat "$TOPIC_MAIN_FIXTURE" ;;
  show)
    printf '%s\n' "$2" >> "$TOPIC_SHOW_LOG"
    jq -r --arg id "$2" '.[] | select(.id == $id) | "task:", "  id: \(.id)", "  kind: captain", "  state: queued", "  hold_kind: captain", "  hold_reason: \(("Question: full detail for " + .id + "? options: yes | no") | tojson)"' "$TOPIC_ROWS_JSON"
    ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$stubbin/tasks-axi"
  printf '# no secondmates\n' > "$home/data/secondmates.md"
  json=$(TOPIC_MAIN_FIXTURE="$home/rows.toon" TOPIC_ROWS_JSON="$home/rows.json" TOPIC_SHOW_LOG="$home/show.log" \
    run_topic "$home" "$stubbin" tf-mut --json) || fail "complete detail read failed"
  jq -e '.counts.decisions == 23 and all(.decisions_open[]; .options == ["yes","no"] and (.hold_reason | startswith("Question: full detail")))' <<<"$json" >/dev/null || fail "some member decisions were not enriched"
  shown=$(wc -l < "$home/show.log" | tr -d ' ')
  [ "$shown" = 23 ] || fail "read unrelated decisions or capped members: $shown reads"
  if grep -q '^other-' "$home/show.log"; then fail "unrelated topic was detail-read"; fi
  pass "all 23 member decisions are enriched after 25 unrelated holds, without reading unrelated details"
}

test_real_cli_tabular_lists_and_scalar_list_fields() {
  local home stubbin json phase title reason
  home=$(make_home real-cli)
  stubbin="$TMP_ROOT/stub-real-cli"
  make_stub_bin "$stubbin" labeled
  printf '# no secondmates\n' > "$home/data/secondmates.md"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  [ -n "$REAL_TASKS_AXI" ] || fail "tasks-axi is required for real table contract verification"
  title='A comma, a "quote", slash \ and café'
  reason='Question: say "yes", or wait? options: A/B | A-B'
  for phase in empty populated; do
    if [ "$phase" = populated ]; then
      TASKS_AXI_FILE="$home/data/backlog.md" "$REAL_TASKS_AXI" add real-a "$title" --kind ship --repo treehouse >/dev/null || fail "real CLI add failed"
      TASKS_AXI_FILE="$home/data/backlog.md" "$REAL_TASKS_AXI" add real-c Other --kind ship --repo outside >/dev/null || fail "real CLI add failed"
      TASKS_AXI_FILE="$home/data/backlog.md" "$REAL_TASKS_AXI" add real-q Queued --kind ship --repo treehouse --blocked-by real-a --blocked-by real-c >/dev/null || fail "real CLI dependencies failed"
      TASKS_AXI_FILE="$home/data/backlog.md" "$REAL_TASKS_AXI" add real-b Decision --kind ship --repo treehouse --pr https://github.com/example/sample/pull/41 --report data/real-b/report.md >/dev/null || fail "real CLI links failed"
      TASKS_AXI_FILE="$home/data/backlog.md" "$REAL_TASKS_AXI" hold real-b --kind captain --reason "$reason" >/dev/null || fail "real CLI hold failed"
    fi
    json=$(SNAPSHOT_FIXTURE="$TMP_ROOT/snapshot.json" FM_DATA_OVERRIDE="$home/data" FM_TOPIC_NOW="$NOW" \
      FM_TOPIC_SNAPSHOT="$stubbin/fmtb-snapshot" "$TOPIC_BRIEF" tf-mut --json) || fail "real $phase list was not parsed"
    if [ "$phase" = empty ]; then
      jq -e '.counts.ready == 0 and .counts.decisions == 0' <<<"$json" >/dev/null || fail "empty real list is not empty"
    else
      jq -e --arg title "$title" --arg reason "$reason" '
        [.next_steps.ready[].id] == ["real-a"] and .next_steps.ready[0].title == $title
        and [.next_steps.blocked[].blocked_by] == [["real-a","real-c"]]
        and .decisions_open[0].hold_reason == $reason and .decisions_open[0].options == ["A/B","A-B"]
        and .decisions_open[0].pr_url == "https://github.com/example/sample/pull/41"
        and .decisions_open[0].report == "data/real-b/report.md"
      ' <<<"$json" >/dev/null || fail "real table scalars, quoting or list fields changed: $json"
    fi
  done
  pass "real CLI empty and populated tables preserve quoted Unicode values, dependencies, links and held decisions"
}

test_unparsed_or_incomplete_task_lists_fail() {
  local home stubbin out rc input
  home=$(make_home malformed-lists)
  stubbin="$TMP_ROOT/stub-malformed"
  make_stub_bin "$stubbin" labeled
  for input in unknown short expanded; do
    case "$input" in
      unknown) printf 'unrecognized populated backlog\n' > "$home/bad.toon" ;;
      short) printf 'tasks[2]{id,state,kind,repo,title}:\n  only-one,queued,ship,treehouse,Work\n' > "$home/bad.toon" ;;
      expanded) printf 'tasks[1]:\n  - id: expanded\n    state: queued\n' > "$home/bad.toon" ;;
    esac
    out=$(TOPIC_MAIN_FIXTURE="$home/bad.toon" run_topic "$home" "$stubbin" tf-mut --json 2>&1) && rc=0 || rc=$?
    [ "$rc" = 2 ] || fail "$input task list was silently accepted: $out"
    case "$out" in *'could not be parsed'*) : ;; *) fail "unparsed list lacks an actionable error: $out" ;; esac
  done
  pass "unknown, incomplete and unsupported expanded lists fail instead of becoming empty topics"
}

test_history_isolates_encoded_topic_names_and_checks_record_identity() {
  local home stubbin topic json out rc record
  home=$(make_home history-isolation)
  stubbin="$TMP_ROOT/stub-history"
  make_stub_bin "$stubbin" labeled
  printf -- '- foo/../bar\n- bar\n- ..\n' > "$home/data/topics.md"
  for topic in foo/../bar bar ..; do
    run_topic "$home" "$stubbin" "$topic" --html "$home/brief.html" >/dev/null || fail "topic history write failed for $topic"
  done
  [ -f "$home/data/topic-briefings/topic-foo%2F..%2Fbar/T20261101T090000Z.json" ] || fail "slash topic key is not encoded"
  [ -f "$home/data/topic-briefings/topic-bar/T20261101T090000Z.json" ] || fail "plain topic history missing"
  [ -f "$home/data/topic-briefings/topic-../T20261101T090000Z.json" ] || fail "parent-like topic key escaped history"
  [ ! -e "$home/data/T20261101T090000Z.json" ] || fail "history escaped its root"
  for topic in foo/../bar bar ..; do
    json=$(run_topic "$home" "$stubbin" "$topic" --json) || fail "isolated history read failed"
    jq -e --arg topic "$topic" '.window.source == "previous-briefing" and (.recap.paragraph | startswith("Topic " + $topic + " briefing "))' <<<"$json" >/dev/null || fail "topic read another topic history: $json"
  done
  record="$home/data/topic-briefings/topic-bar/T20261101T090000Z.json"
  jq '.topic = "foo/../bar"' "$record" > "$home/wrong.json"
  mv "$home/wrong.json" "$record"
  out=$(run_topic "$home" "$stubbin" bar --since 2026-10-30 --json 2>&1) && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "mismatched topic record was used for recap: $out"
  pass "topic keys cannot collide or traverse; history reads reject another topic record even with --since"
}

test_every_home_and_read_stage_is_bounded() {
  local home stubbin placement stage out rc
  for placement in main local remote; do
    for stage in list fallback detail; do
      home=$(make_home "bounded-$placement-$stage")
      stubbin="$home/fakebin"
      make_stub_bin "$stubbin" labeled
      cat > "$stubbin/tasks-axi" <<'SH'
#!/usr/bin/env bash
owner="${TOPIC_READ_OWNER:-main}"
case "${TASKS_AXI_FILE:-}" in */mate/data/backlog.md) owner=mate ;; esac
if [ "$owner" = "$TOPIC_STALL_OWNER" ]; then
  case "$TOPIC_STALL_STAGE:${1:-}:${3:-}" in
    fallback:list:labels,*) printf 'Unknown field(s): labels\n'; exit 2 ;;
    list:list:*|fallback:list:*|detail:show:*) sleep 3 ;;
  esac
fi
case "${1:-}" in
  list) cat "$TOPIC_TABLE_FIXTURE" ;;
  show) cat "$TOPIC_SHOW_FIXTURE" ;;
  *) exit 9 ;;
esac
SH
      cat > "$home/ssh" <<'SH'
#!/usr/bin/env bash
args=()
while IFS= read -r arg; do args+=("$arg"); done < <(printf '%s' "${!#}" | base64 -d | tr '\0' '\n')
[ "${args[0]}" = fm-tasks-axi.sh ] || exit 9
TOPIC_READ_OWNER=mate exec "$TOPIC_STALL_BIN" "${args[@]:1}"
SH
      chmod +x "$stubbin/tasks-axi" "$home/ssh"
      if [ "$placement" = remote ]; then
        printf -- '- mate - Fixture (host: fixturehost; root: %s; home: %s/mate; scope: tests; projects: treehouse; added 2026-10-01)\n' "$ROOT" "$home" > "$home/data/secondmates.md"
      elif [ "$placement" = main ]; then
        printf '# no secondmates\n' > "$home/data/secondmates.md"
      fi
      out=$(TOPIC_STALL_OWNER="$([ "$placement" = main ] && printf main || printf mate)" TOPIC_STALL_STAGE="$stage" \
        TOPIC_TABLE_FIXTURE="$TMP_ROOT/list-labels.toon" TOPIC_SHOW_FIXTURE="$TMP_ROOT/show-t-dec.toon" \
        TOPIC_STALL_BIN="$stubbin/tasks-axi" FM_SSH_BIN="$home/ssh" FM_TOPIC_READ_TIMEOUT=1 \
        run_topic "$home" "$stubbin" tf-mut --json 2> "$home/error") && rc=0 || rc=$?
      if [ "$placement" = main ] && [ "$stage" != detail ]; then
        [ "$rc" = 2 ] || fail "main $stage read was not bounded: rc=$rc"
      else
        [ "$rc" = 0 ] || fail "$placement $stage timeout failed the whole briefing"
        if [ "$stage" = detail ]; then
          jq -e 'any(.disclosures[]; contains("detail unavailable"))' <<<"$out" >/dev/null || fail "$placement detail timeout was hidden"
        else
          jq -e 'any(.disclosures[]; contains("backlog unavailable"))' <<<"$out" >/dev/null || fail "$placement $stage timeout was hidden"
        fi
      fi
    done
  done
  pass "main, local-mate and remote-mate list, fallback and detail reads terminate at the configured bound"
}

fm_test_run \
  test_label_alias_project_membership \
  test_decision_options_and_detail_enrichment \
  test_label_fallback \
  test_window_default_since_and_recap \
  test_recap_and_history_read \
  test_registry_errors \
  test_registry_optional_fields \
  test_json_and_summary_are_exclusive \
  test_html_self_containment_and_answers_line \
  test_board_payload_shape \
  test_secondmate_membership_all_surfaces \
  test_deferred_calls_and_resolved_dependencies \
  test_external_holds_remain_blocked_in_every_home_and_output \
  test_chat_details_and_read_only_modes \
  test_registry_name_alias_collisions \
  test_portable_dates_and_calendar_validation \
  test_publication_failure_preserves_history_and_empty_states \
  test_coverage_disclosures_in_every_mode \
  test_complete_distinct_board_options \
  test_enriched_decisions_recheck_each_home_state \
  test_latest_offline_answer_wins \
  test_board_preserves_work_modes_dates_and_empty_defaults \
  test_snapshot_delivery_artifacts_reach_every_output \
  test_all_and_only_topic_decisions_are_enriched \
  test_real_cli_tabular_lists_and_scalar_list_fields \
  test_unparsed_or_incomplete_task_lists_fail \
  test_history_isolates_encoded_topic_names_and_checks_record_identity \
  test_every_home_and_read_stage_is_bounded
