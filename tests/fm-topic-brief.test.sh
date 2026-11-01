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
# The suite never depends on the host tasks-axi supporting labels: every
# ledger read is served by PATH stubs (one with a labels-capable list, one
# that reproduces the installed 0.2.x "Unknown field(s): labels" refusal), so
# the fallback path is exercised by construction.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOPIC_BRIEF="$ROOT/bin/fm-topic-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-topic-brief)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

NOW=2026-11-01T09:00:00Z

# --- fixture builders --------------------------------------------------------

make_home() {  # <name> -> prints home dir; writes registry + fixture state
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
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
case "\${3:-}" in
  labels,*) # the label-capable field list
$([ "$mode" = labeled ] && printf '    cat "%s"\n    exit 0\n' "$fixture" || printf '    cat "%s/nolabel-refusal.txt"\n    exit 2\n' "$TMP_ROOT")
    ;;
esac
case "\${1:-}" in
  list) cat "$fixture" ;;
  show) cat "$TMP_ROOT/show-t-dec.toon" ;;
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

write_fixtures() {
  cat > "$TMP_ROOT/list-labels.toon" <<'EOF'
count: 8
tasks[8]:
  - id: t-lab
    state: queued
    kind: ship
    repo: treehouse
    title: "Labelled member, plain title"
    labels[1]: "topic:tf-mut"
    blocked_by: none
    created: 2026-10-20
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-alias
    state: queued
    kind: ship
    repo: other-repo
    title: "Member via alias label"
    labels[1]: "topic:mut"
    blocked_by: none
    created: 2026-10-21
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-proj
    state: queued
    kind: ship
    repo: treehouse
    title: "Member by default project, unlabelled"
    labels: []
    blocked_by[1]: t-lab
    created: 2026-10-22
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-out
    state: queued
    kind: ship
    repo: other-repo
    title: "Carries another topic label"
    labels[1]: "topic:crew-wiki"
    blocked_by: none
    created: 2026-10-23
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-topicless
    state: queued
    kind: ship
    repo: treehouse
    title: "Has a topic label for another topic"
    labels[1]: "topic:crew-wiki"
    blocked_by: none
    created: 2026-10-24
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-dec
    state: queued
    kind: ship
    repo: treehouse
    title: "Held member with captain question"
    labels[1]: "topic:tf-mut"
    blocked_by: none
    created: 2026-10-25
    closed: "-"
    held: yes
    hold_kind: captain
    hold_until: 2026-11-15
    links: none
    hold_reason: "Question: which merge posture for topic briefings? Full context: the captain asked for topic briefings on 2026-10-20. options: yolo on | yolo off | defer a week"
  - id: t-done
    state: done
    kind: ship
    repo: treehouse
    title: "Landed member row with PR"
    labels[1]: "topic:tf-mut"
    blocked_by: none
    created: 2026-10-18
    closed: 2026-10-28
    held: no
    hold_kind: "-"
    hold_until: "-"
    links[1]: "pr:https://github.com/andrewesweet/treehouse/pull/42"
    hold_reason: "-"
  - id: t-answ
    state: done
    kind: captain
    repo: "-"
    title: "Topic briefings: start now"
    labels[1]: "topic:tf-mut"
    blocked_by: none
    created: 2026-10-19
    closed: 2026-10-26
    held: no
    hold_kind: captain
    hold_until: "-"
    links[1]: "report:data/t-dec/report.md"
    hold_reason: "Captain decision: start now"
help[2]:
  - "Run `tasks-axi show <id>` for full notes on a task"
  - "Field semantics live in the tasks-axi docs"
EOF
  # The same ledger as the installed 0.2.x would render it: no labels field at
  # all, and only five rows because the remaining fixtures exist to test
  # label-driven membership.
  cat > "$TMP_ROOT/list-nolabels.toon" <<'EOF'
count: 5
tasks[5]:
  - id: t-lab
    state: queued
    kind: ship
    repo: treehouse
    title: "Labelled member, plain title"
    blocked_by: none
    created: 2026-10-20
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-alias
    state: queued
    kind: ship
    repo: other-repo
    title: "Member via alias label"
    blocked_by: none
    created: 2026-10-21
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-proj
    state: queued
    kind: ship
    repo: treehouse
    title: "Member by default project, unlabelled"
    blocked_by[1]: t-lab
    created: 2026-10-22
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-out
    state: queued
    kind: ship
    repo: other-repo
    title: "Carries another topic label"
    blocked_by: none
    created: 2026-10-23
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
  - id: t-topicless
    state: queued
    kind: ship
    repo: treehouse
    title: "Has a topic label for another topic"
    blocked_by: none
    created: 2026-10-24
    closed: "-"
    held: no
    hold_kind: "-"
    hold_until: "-"
    links: none
    hold_reason: "-"
help[1]:
  - "Run `tasks-axi show <id>` for full notes on a task"
EOF
  printf 'Unknown field(s): labels. Available: blocked, blocked_by, body, closed, created, delivery_state, deps, held, hold_kind, hold_until, links, hold_reason\n' > "$TMP_ROOT/nolabel-refusal.txt"
  cat > "$TMP_ROOT/show-t-dec.toon" <<'EOF'
task:
  id: t-dec
  state: queued
  kind: ship
  repo: treehouse
  title: "Held member with captain question (full title from detail)"
  labels[1]: "topic:tf-mut"
  blocked_by: none
  created: 2026-10-25
  closed: "-"
  held: yes
  hold_kind: captain
  hold_until: 2026-11-15
  links[1]: "report:data/t-dec/report.md"
  hold_reason: "Question: which merge posture for topic briefings? Full context: the captain asked for topic briefings on 2026-10-20. options: yolo on | yolo off | defer a week"
help[1]:
  - "Run `tasks-axi show <id>` for full notes on a task"
EOF
  cat > "$TMP_ROOT/snapshot.json" <<'EOF'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-11-01T08:00:00Z",
  "in_flight": [
    { "id": "t-flight", "kind": "ship", "state": "in_flight", "repo": "treehouse", "name": "Main child in flight", "doing": "landing the pipeline", "owner": "(main)" },
    { "id": "t-other-flight", "kind": "ship", "state": "in_flight", "repo": "other-repo", "name": "Other repo flight", "doing": "work", "owner": "(main)" },
    { "id": "mate/t-flight", "kind": "ship", "state": "in_flight", "repo": "treehouse", "name": "Second-mate child in flight", "doing": "checking labels", "owner": "mate" },
    { "id": "mate/t-nowhere", "kind": "ship", "state": "in_flight", "repo": null, "name": "Second-mate no-repo flight", "doing": "work", "owner": "mate" }
  ],
  "decisions": [
    { "id": "t-dec", "verb": "decide", "summary": "main held decision", "repo": "treehouse", "owner": "(main)" },
    { "id": "mate/t-dec2", "verb": "decide", "summary": "second-mate decision", "repo": null, "owner": "mate" }
  ],
  "landed": [
    { "id": "t-done", "what": "Landed member row with PR", "pr_url": "https://github.com/andrewesweet/treehouse/pull/42", "repo": "treehouse", "owner": "(main)" },
    { "id": "mate/t-done2", "what": "Second-mate landed row", "pr_url": null, "repo": null, "owner": "mate" }
  ],
  "recorded_prs": { "t-flight": "https://github.com/andrewesweet/treehouse/pull/77" }
}
EOF
}

write_fixtures

run_topic() {  # <home> <stubbin> <args...>
  local home="$1" stubbin="$2"
  shift 2
  SNAPSHOT_FIXTURE="$TMP_ROOT/snapshot.json" \
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
  [ "$landed" = '["t-done","t-answ"]' ] || fail "landed membership wrong: $landed"
  [ "$flight" = '["mate/t-flight"]' ] || fail "second-mate in-flight membership wrong: $flight"
  [ "$decisions" = '["t-dec"]' ] || fail "decision membership wrong: $decisions"
  local prurl
  prurl=$(jq -r '[.changed_since.landed[] | select(.id == "t-done") | .pr_url][0]' <<<"$json")
  [ "$prurl" = "https://github.com/andrewesweet/treehouse/pull/42" ] || fail "recorded PR URL missing from landed row: $prurl"
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
  [ -f "$home/data/topic-briefings/tf-mut/T20261101T090000Z.json" ] || fail "history record not written"
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
  pass "recap: second briefing carries the previous briefing's summary"
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
  # The second-mate no-repo disclosure must be visible in the page.
  printf '%s' "$html" | grep -q 'class="disclosure"' || fail "HTML missing disclosure block"
  pass "HTML: self-contained, mobile viewport, inline SVG, noscript answers doc, answers line"
}

test_board_payload_shape() {
  local home stubbin capture opts
  home=$(make_home board)
  stubbin="$TMP_ROOT/stub-labeled"
  make_stub_bin "$stubbin" labeled
  capture="$TMP_ROOT/captured-board.json"
  cat > "$stubbin/fm-bearings-board" <<EOF
#!/usr/bin/env bash
# Test seam for FM_TOPIC_BOARD_CMD: capture the composed payload verbatim.
printf '%s\n' "\$*" >> "$stubbin/board-calls.log"
[ "\${1:-}" = build ] && cp "\$2" "$capture" && exit 0
exit 9
EOF
  chmod +x "$stubbin/fm-bearings-board"
  SNAPSHOT_FIXTURE="$TMP_ROOT/snapshot.json" PATH="$stubbin:$PATH" \
    FM_DATA_OVERRIDE="$home/data" FM_TOPIC_SNAPSHOT="$stubbin/fmtb-snapshot" \
    FM_TOPIC_BOARD_CMD="$stubbin/fm-bearings-board" FM_TOPIC_NOW="$NOW" \
    "$TOPIC_BRIEF" tf-mut --board >/dev/null || fail "--board with stubbed board command failed"
  [ -f "$capture" ] || fail "board command was not invoked with a payload"
  opts=$(jq -c '[.captains_call[0].options[].value]' "$capture")
  [ "$opts" = '["yolo-on","yolo-off","defer-a-week"]' ] || fail "board option values must be slugs: $opts"
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
  [ "$mateflight" = '["mate/t-flight"]' ] || fail "board underway should carry only topic member rows: $mateflight"
  pass "board payload: slug values with recorded labels, topic-scoped rows, shape contract"
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
  test_board_payload_shape
