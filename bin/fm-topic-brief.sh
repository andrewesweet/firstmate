#!/usr/bin/env bash
# fm-topic-brief.sh - rebuild one topic's briefing from durable records only.
#
# "Brief me on <topic>" mechanics: resolve the topic through the operational
# home's topic registry, project the fleet's existing bearings snapshot plus
# this home's backlog down to the topic, render a self-contained HTML briefing
# with an offline pick-and-copy answers block, append the topic's briefing
# history, and optionally open the topic's decisions on the existing
# interactive bearings board.
#
# Usage:
#   fm-topic-brief.sh <topic> [--since <YYYY-MM-DD>] [--json] [--html <out>] [--board]
#   fm-topic-brief.sh --help
#
# Flags:
#   <topic>        Topic name or alias from the registry.
#   --since DATE   Window start (YYYY-MM-DD, UTC). Overrides the previous
#                  briefing's generation time. Default window: previous
#                  briefing's generation time, else now minus 14 days. The
#                  window always ends now.
#   --json         Print the topic model (schema fm-topic-brief.v1) and exit;
#                  the chat summary is the no-flag output, so --json never
#                  mixes the two on stdout.
#   --html OUT     Write the self-contained HTML briefing to OUT and append a
#                  history record under data/topic-briefings/<topic>/ (--html
#                  is the only flag that writes history).
#   --board        Additionally open the topic's decisions on the existing
#                  interactive bearings board by composing an
#                  fm-bearings-board.v1 payload and running
#                  bin/fm-bearings-board.sh build. Reuses the board's existing
#                  captured-answer binding keyed by held task id (the board
#                  build owns the bind; no new answer intake, keying scheme or
#                  decision record is introduced). The board is rebuilt with
#                  this topic's rows only; the next /bearings lavish rebuild
#                  restores the whole fleet.
#
# With no flags, prints a short TOON-style chat summary for the invoking agent
# to relay next to the briefing.
#
# Registry syntax and membership: docs/configuration.md "Topic registry".
#
# Options as given (hold reasons): the model never invents options. When a
# hold reason contains an `options:` marker (preceded by line start or a
# non-letter), the items after it, separated by " | " to the end of that line,
# are the decision's offered options. Without the marker the decision offers
# freeform text plus the standard reconcile choice. The marker is an optional convention; prose-only
# reasons stay fully usable.
#
# Answers block (offline pick-and-copy): each decision card offers its options
# as radio controls plus a freeform input; the copy control emits one line
#   TOPIC-ANSWERS v1 | topic=<name> | answered=<n>/<m> | <task-id>=<value> | ...
# where <value> is the picked option text, the typed answer, or "reconcile".
# Pipe characters in values are sanitised to ";" and newlines to spaces so the
# line stays parseable. All content stays readable with scripting disabled;
# without JS the page documents the line format manually.
#
# History: data/topic-briefings/<topic>/T<UTC-timestamp>.json records topic,
# generated time, window, counts, and a one-paragraph recap. The next run
# reads the latest record for its window ("since last briefing") and its
# recap paragraph. No history means the 14-day default window and no recap.
#
# Sources of truth and failure modes:
#   - PR and report URLs come only from recorded sources: task links
#     (tasks-axi link fields), completion artefacts (snapshot landed rows),
#     and recorded_prs in the snapshot. URLs are never assembled from task ids
#     or titles.
#   - A missing or unreadable remote ledger shows up exactly as bearings
#     reports it (unknown second-mate state), disclosed, never as empty.
#   - Usage errors, a missing or malformed registry, an unknown topic, an
#     invalid --since date, or a failed snapshot/backlog read exit 2 with an
#     actionable message.
#
# Field-value conventions parsed from tasks-axi TOON output: "-" is a null
# scalar, "none" is an empty list, "[]" is an empty list, inline arrays use
# [N]: with comma-separated quoted-or-bare items, and quoted scalars use
# JSON-style backslash escapes.
#
# Tests override points (tests only, never set in production):
#   FM_TOPIC_SNAPSHOT   command used instead of bin/fm-bearings-snapshot.sh
#                       (fixture snapshots; word-split, then given the usual
#                       snapshot flags).
#   FM_TOPIC_BOARD_CMD  command used instead of bin/fm-bearings-board.sh
#                       (test seam; the real build keeps the binding and
#                       reconcile behavior)
#   FM_TOPIC_NOW        fixed "now" (ISO-8601 UTC) for deterministic windows.
#
# Set FM_HOME (or FM_DATA_OVERRIDE) to target a specific operational home;
# the default is this script's repository root, the fleet's single-home
# layout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() { sed -n '2,${/^#/!q;p;}' "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'; }

fail() {
  printf 'fm-topic-brief: %s\n' "$1" >&2
  exit 2
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool '$1' is not available"
}
need jq

TOPIC_NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [ -n "${FM_TOPIC_NOW:-}" ]; then TOPIC_NOW="$FM_TOPIC_NOW"; fi

TOPIC_QUERY=""
TOPIC_SINCE_FLAG=""
TOPIC_JSON=0
TOPIC_HTML_OUT=""
TOPIC_BOARD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --since)
      [ $# -ge 2 ] || fail "--since requires a YYYY-MM-DD date"
      TOPIC_SINCE_FLAG="$2"; shift 2 ;;
    --json) TOPIC_JSON=1; shift ;;
    --html)
      [ $# -ge 2 ] || fail "--html requires an output path"
      TOPIC_HTML_OUT="$2"; shift 2 ;;
    --board) TOPIC_BOARD=1; shift ;;
    -*) fail "unknown option: $1" ;;
    *)
      if [ -z "$TOPIC_QUERY" ]; then TOPIC_QUERY="$1"; shift
      else fail "unexpected extra argument: $1 (only one topic per run)"
      fi ;;
  esac
done
[ -n "$TOPIC_QUERY" ] || fail "usage: fm-topic-brief.sh <topic> [--since <date>] [--json] [--html <out>] [--board]"

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

TOPIC_REGISTRY="$DATA/topics.md"

topic_registry_json() {
  # Parse data/topics.md into JSON. Skip blanks and #-comments; every other
  # line must be "- <name> [| aliases: <csv>] [| projects: <csv>]". Exits 2
  # naming file and line on malformed input, duplicates, or invalid suffixes.
  if [ ! -f "$TOPIC_REGISTRY" ]; then
    fail "no topics are registered: $TOPIC_REGISTRY is absent (create it per docs/configuration.md 'Topic registry')"
  fi
  awk -v file="$TOPIC_REGISTRY" '
    /^[ \t]*$/ { next }
    /^#/ { next }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line !~ /^- /) {
        printf "fm-topic-brief: malformed topic registry: %s line %d: topic lines start with \"- \"\n", file, NR > "/dev/stderr"
        exit 1
      }
      sub(/^- /, "", line)
      n = split(line, fields, "|")
      name = ""; aliases = ""; projects = ""
      for (i = 1; i <= n; i++) {
        f = fields[i]
        gsub(/^[ \t]+/, "", f); gsub(/[ \t]+$/, "", f)
        if (i == 1) { name = f; continue }
        if (f ~ /^aliases[ \t]*:/) { aliases = substr(f, index(f, ":") + 1) }
        else if (f ~ /^projects[ \t]*:/) { projects = substr(f, index(f, ":") + 1) }
        else {
          printf "fm-topic-brief: malformed topic registry: %s line %d: unknown field (expected \"- name | aliases: ... | projects: ...\")\n", file, NR > "/dev/stderr"
          exit 1
        }
        gsub(/^[ \t]+/, "", aliases); gsub(/[ \t]+$/, "", aliases)
        gsub(/^[ \t]+/, "", projects); gsub(/[ \t]+$/, "", projects)
      }
      if (name == "" || name ~ /[ \t|]/) {
        printf "fm-topic-brief: malformed topic registry: %s line %d: topic name must be a non-empty label suffix with no spaces or pipes\n", file, NR > "/dev/stderr"
        exit 1
      }
      printf "%s\t%s\t%s\n", name, aliases, projects
    }
  ' "$TOPIC_REGISTRY" > "$TOPIC_TMP/registry.tsv" || exit 2
  jq -Rn '
    def trims: gsub("^[ \\t]+"; "") | gsub("[ \\t]+$"; "");
    def splitlist: trims | split(",") | map(trims | select(length > 0));
    [inputs | [splits("\t")] |
      { name: (.[0] | trims),
        aliases: (.[1] | splitlist),
        projects: (.[2] | splitlist) }
    ] as $topics |
    ($topics | map(.name) | group_by(.) | map(select(length > 1)) | .[0][0]) as $dupname |
    ($topics | map(.name, .aliases[]) | group_by(.) | map(select(length > 1)) | .[0][0]) as $dupalias |
    ([$topics[] | .name as $n | ([( $n )] + .aliases) | select(any(test("^[a-z0-9._/:_-]{1,58}$") | not)) | "\(.)"] | .[0]) as $badsuffix |
    ([$topics[] | .projects[] | select(test("^[A-Za-z0-9._/-]{1,128}$") | not)] | .[0]) as $badproj |
    if ($topics | length) == 0 then error("no topics defined in " + $regfile)
    elif $dupname != null then error("duplicate topic name: " + $dupname)
    elif $dupalias != null then error("duplicate topic name or alias: " + $dupalias)
    elif $badsuffix != null then error("topic label suffix must be lowercase alphanumerics plus . _ / : - (1..58 chars): " + $badsuffix)
    elif $badproj != null then error("project tag must be alphanumerics plus . _ / - (1..128 chars): " + $badproj)
    else $topics end
  ' --arg regfile "$TOPIC_REGISTRY" < "$TOPIC_TMP/registry.tsv" > "$TOPIC_TMP/registry.json" 2> "$TOPIC_TMP/registry.err" || {
    head -1 "$TOPIC_TMP/registry.err" | sed 's/^jq: error (at .*): /fm-topic-brief: malformed topic registry: /; s/^jq: error: /fm-topic-brief: malformed topic registry: /' >&2
    exit 2
  }
}

# ---------------------------------------------------------------------------
# TOON parsing (tasks-axi list and detail output)
# ---------------------------------------------------------------------------

topic_toon_parse() {
  # Parse tasks-axi TOON output on stdin into a JSON array of row objects.
  # Handles list rows ("  - id: ..."), detail blocks ("task:" + "  id: ..."),
  # field lines, quoted scalars with escapes, inline "[N]: a,\"b\"" arrays,
  # and the "none" / "-" / "[]" conventions. Parsing stops at the help block.
  jq -Rs -f <(cat <<'JQ'
    def unescape:
      . as $s |
      {out: [], esc: false}
      | reduce ($s | explode[]) as $ch (.;
          if .esc then
            .out += (if $ch == 110 then [10] elif $ch == 116 then [9] elif $ch == 34 then [34] elif $ch == 92 then [92] else [92, $ch] end)
            | .esc = false
          elif $ch == 92 then .esc = true
          else .out += [$ch]
          end)
      | .out | implode;
    def toonval:
      if . == "[]" then []
      elif (startswith("\"") and endswith("\"") and length >= 2) then .[1:length-1] | unescape
      else . end;
    def commalist:
      . as $s |
      {parts: [], cur: [], inq: false, esc: false}
      | reduce ($s | explode[]) as $ch (.;
          if .esc then .cur += [$ch] | .esc = false
          elif $ch == 92 then .cur += [$ch] | .esc = true
          elif $ch == 34 then .inq = (.inq | not) | .cur += [$ch]
          elif $ch == 44 and (.inq | not) then
            .parts += [(.cur | implode)] | .cur = []
          else .cur += [$ch]
          end)
      | (.parts + [(.cur | implode)])
      | map(toonval)
      | map(select(length > 0));
    split("\n") as $lines |
    (($lines | map(test("^help\\[")) | index(true)) // ($lines | length)) as $cutoff |
    [($lines[:$cutoff][] | select(length > 0) |
      capture("^(?<lead>[ \\t]*)(?<dash>- )?(?<k>[A-Za-z_][A-Za-z0-9_]*)(?<arr>\\[[0-9]+\\])?: ?(?<v>.*)$"))] as $fields |
    {rows: [], cur: null}
    | reduce ($fields[]) as $f (.;
        if $f.dash != null then
          (.rows += [(.cur // {})]) | .cur = {($f.k): ($f.v | toonval)}
        elif .cur == null and $f.k == "id" then
          .cur = {($f.k): ($f.v | toonval)}
        elif .cur == null then .
        elif ($f.arr | length) > 0 then
          .cur[$f.k] = ($f.v | commalist)
        else
          .cur[$f.k] = ($f.v | toonval)
        end)
    | (.rows += [(.cur // {})])
    | .rows
    | map(select(has("id")))
JQ
  ) 2> "$TOPIC_TMP/parse.err"
}

# ---------------------------------------------------------------------------
# Backlog reads (through bin/fm-tasks-axi.sh, never data/backlog.md)
# ---------------------------------------------------------------------------

TOPIC_TASKS_AXI="$SCRIPT_DIR/fm-tasks-axi.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

topic_tasks() {
  local owner="$1"
  shift
  if [ "$owner" = "(main)" ]; then
    "$TOPIC_TASKS_AXI" "$@"
  else
    secondmate_registry_line_for_id "$DATA/secondmates.md" "$owner" || return 2
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      "$SCRIPT_DIR/fm-on.sh" "$owner" fm-tasks-axi.sh "$@"
    else
      FM_HOME="$SECONDMATE_REGISTRY_HOME" FM_DATA_OVERRIDE="$SECONDMATE_REGISTRY_HOME/data" \
        "$TOPIC_TASKS_AXI" "$@"
    fi
  fi
}

[ -f "$TOPIC_TASKS_AXI" ] || fail "missing helper: $TOPIC_TASKS_AXI"

topic_backlog_rows() {
  # Read all backlog rows; returns 0 with labels, 3 with the label-fallback
  # read (labels unavailable), and returns 2 on any other error.
  if topic_tasks "$1" list --fields "labels,blocked_by,created,closed,held,hold_kind,hold_until,links,hold_reason" \
      > "$TOPIC_TMP/list.raw" 2> "$TOPIC_TMP/axi.err"; then
    return 0
  fi
  # tasks-axi 0.2.x prints validation errors on stdout; 0.3+ may use stderr.
  if grep -q 'Unknown field' "$TOPIC_TMP/axi.err" "$TOPIC_TMP/list.raw" 2>/dev/null; then
    if topic_tasks "$1" list --fields "blocked_by,created,closed,held,hold_kind,hold_until,links,hold_reason" \
        > "$TOPIC_TMP/list.raw" 2>> "$TOPIC_TMP/axi.err"; then
      return 3
    fi
  fi
  printf 'fm-topic-brief: backlog read failed: ' >&2
  { head -2 "$TOPIC_TMP/axi.err" 2>/dev/null; head -1 "$TOPIC_TMP/list.raw" 2>/dev/null; } | tr '\n' ' ' >&2
  printf '\n' >&2
  return 2
}

topic_collect_rows() {
  local owner="$1" rc
  topic_backlog_rows "$owner"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    [ "$owner" != "(main)" ] || fail "cannot read main backlog"
    printf '%s\n' "secondmate $owner backlog unavailable; topic membership is unknown" >> "$TOPIC_TMP/coverage.txt"
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    TOPIC_LABELS_NOTE="the installed tasks-axi does not support --fields labels; membership fell back to default projects only"
    printf '%s\n' "$owner: $TOPIC_LABELS_NOTE" >> "$TOPIC_TMP/coverage.txt"
  fi
  topic_toon_parse < "$TOPIC_TMP/list.raw" > "$TOPIC_TMP/parsed.json" || return 2
  jq --arg owner "$owner" '
    map(. + {owner: $owner, task_id: .id}
      | if $owner == "(main)" then . else
          .id = ($owner + "/" + .id)
          | .blocked_by = ((.blocked_by | if type == "array" then . else [] end) | map($owner + "/" + .))
        end)
  ' "$TOPIC_TMP/parsed.json" >> "$TOPIC_TMP/rows.ndjson"
}

# ---------------------------------------------------------------------------
# Snapshot (the fleet's bearings projection)
# ---------------------------------------------------------------------------

TOPIC_SNAPSHOT_CMD="${FM_TOPIC_SNAPSHOT:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"

topic_snapshot() {
  # shellcheck disable=SC2086 # test fixtures may pass a word-split command
  read -r -a topic_snap_cmd <<< "$TOPIC_SNAPSHOT_CMD"
  "${topic_snap_cmd[@]}" --json --all-decisions --all-in-flight --all-landed --all-recorded-prs --all-secondmates \
    > "$TOPIC_TMP/snapshot.json" 2> "$TOPIC_TMP/snapshot.err"
  local rc=$?
  if [ $rc -ne 0 ]; then
    printf 'fm-topic-brief: bearings snapshot failed (exit %s)' "$rc" >&2
    [ -s "$TOPIC_TMP/snapshot.err" ] && { printf ': ' >&2; head -2 "$TOPIC_TMP/snapshot.err" | tr '\n' ' ' >&2; }
    printf '\n' >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

topic_history_dir() { printf '%s/topic-briefings/%s' "$DATA" "$1"; }

topic_history_latest() {
  local dir="$1" latest
  [ -d "$dir" ] || return 0
  latest="$(find "$dir" -maxdepth 1 -name 'T*.json' -type f 2>/dev/null | LC_ALL=C sort | tail -1)"
  [ -n "$latest" ] && printf '%s' "$latest"
  return 0
}

topic_history_record() {
  # $1 = history dir, $2 = model file. Writes T<stamp>.json from the model.
  local dir="$1" model_file="$2" stamp out tmp
  mkdir -p "$dir" || fail "cannot create history directory: $dir"
  stamp="$(jq -r '.generated' "$model_file" | sed 's/[-:]//g')"
  out="$dir/T${stamp}.json"
  tmp="$dir/.T${stamp}.$$.tmp"
  jq '{schema: "fm-topic-brief-record.v1", topic: .topic.name, generated, window, counts, recap: .recap_next}' \
    "$model_file" > "$tmp" || fail "cannot render history record"
  mv "$tmp" "$out" || fail "cannot write history record: $out"
}

# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

topic_model() {
  jq -n \
    --slurpfile registry "$TOPIC_TMP/entry.json" \
    --slurpfile rows "$TOPIC_TMP/rows.json" \
    --slurpfile details "$TOPIC_TMP/details.json" \
    --slurpfile snapshot "$TOPIC_TMP/snapshot.json" \
    --slurpfile prev "$TOPIC_TMP/prev.json" \
    --rawfile coverage "$TOPIC_TMP/coverage.txt" \
    --arg now "$TOPIC_NOW" \
    --arg since "$TOPIC_SINCE" \
    --arg since_source "$TOPIC_SINCE_SOURCE" \
    --arg labels_note "$TOPIC_LABELS_NOTE" \
    --arg held_note "$TOPIC_HELD_NOTE" \
    '
    def nul: if . == "-" or . == "none" then null else . end;
    def arr: if (type == "array") then . else [] end;
    def links_split: (.links | arr |
      map(if contains(":") then {kind: (split(":")[0]), url: sub("^[^:]+:"; "")}
          else {kind: "other", url: .} end));
    def prurl: (links_split | map(select(.kind == "pr")) | (.[0].url // null));
    def reporturl: (links_split | map(select(.kind == "report")) | (.[0].url // null));
    def heldyes: (((.held // "no") | tostring) | test("^(yes|true)$"));
    def d10: ((. // "")[0:10]);
    def closedinwin: (.closed != null and ((.closed | d10) >= ($since | d10)) and ((.closed | d10) <= ($now | d10)));
    def createdinwin: (.created != null and ((.created | d10) >= ($since | d10)) and ((.created | d10) <= ($now | d10)));

    ($registry[0]) as $t |
    ($rows[0] | map(. + {
        labels: (.labels | arr),
        repo: (.repo | nul),
        blocked_by: (.blocked_by | arr),
        closed: (.closed | nul),
        created: (.created | nul),
        hold_until: (.hold_until | nul),
        hold_kind: (.hold_kind | nul),
        hold_reason: ((.hold_reason | nul) // "")
      })) as $rows |
    ($details[0] | map(. + {
        labels: (.labels | arr),
        repo: (.repo | nul),
        blocked_by: (.blocked_by | arr),
        links: (.links | arr),
        closed: (.closed | nul),
        created: (.created | nul),
        hold_until: (.hold_until | nul),
        hold_kind: (.hold_kind | nul),
        hold_reason: ((.hold_reason | nul) // "")
      })) as $details |
    ($snapshot[0]) as $snap |
    ($prev[0]) as $prev |
    ($t.projects) as $projects |
    (["topic:" + $t.name] + ($t.aliases | map("topic:" + .))) as $wantlabels |

    # membership over home rows
    ([$rows[] |
      (.labels | map(select(. as $l | $wantlabels | index($l)))) as $hit |
      if ($hit | length) > 0 then {id: .id, how: "label"}
      elif ((.labels | map(select(startswith("topic:"))) | length) == 0)
        and ((.repo // "") != "") and (.repo as $r | ($projects | index($r)) != null)
      then {id: .id, how: "project"}
      else empty end] | map(.id)) as $memberids |
    ($rows | map(select(.id as $id | ($memberids | index($id))))) as $members |

    ($members | map(select(.state == "done" and closedinwin))) as $closed |
    ($closed | map(select(.hold_kind == "captain" or .kind == "captain"))) as $answered |
    ($closed | map(. as $row | select(any($snap.landed[]?; .id == $row.task_id and (.owner // "(main)") == $row.owner)))) as $landed |
    ($members | map(select(createdinwin and .state != "done"))) as $newrows |

    ($members | map(select(.hold_kind == "captain" and .state != "done"))) as $heldrows |
    ($heldrows | map(. as $r | $r + ((($details | map(select(.id == $r.id)))[0]) // {}))) as $heldetails |

    ($snap.recorded_prs // [] | map({key: .id, value: .url}) | from_entries) as $recprs |
    ($snap.in_flight // [] | map(. as $f |
      (($members | map(select(.id == $f.id)))[0]) as $r |
      select($r != null) |
      {
        id: $f.id,
        name: ($f.name // $r.title // $f.id),
        kind: ($f.kind // $r.kind // "ship"),
        state: ($f.state // "in_flight"),
        repo: ($f.repo // $r.repo // null),
        doing: ($f.doing // ""),
        owner: $r.owner,
        pr_url: ($recprs[$f.id] // ($r | prurl))
      })) as $flight |

    ($members | map(select(.state == "queued" and (heldyes | not) and .hold_kind != "captain")
      | .blocked_by |= map(. as $id | select(any($rows[]; .id == $id and .state == "done") | not)))) as $queued |
    ($queued | map(select((.blocked_by | length) == 0))) as $ready |
    ($queued | map(select((.blocked_by | length) > 0))) as $blocked |

    # timeline
    ([$closed[] |
        {date: .closed,
         kind: (if .hold_kind == "captain" or .kind == "captain" then "answered"
                elif (.id as $id | any($landed[]; .id == $id)) then "landed"
                else "closed" end),
         id: .id, label: .title}] +
     [$newrows[] | {date: .created, kind: "filed", id: .id, label: .title}] +
     (if (($prev.generated // "") != "") then
        [{date: $prev.generated, kind: "briefing", id: null, label: "previous briefing"}]
      else [] end)
     | sort_by(.date)) as $timeline |

    ([if ($held_note | length) > 0 then $held_note else empty end] +
      ($coverage | split("\n") | map(select(length > 0))) +
      [$snap.secondmates[]? | select(.state == "unknown" or .freshness != "fresh" or .provenance == "structured-home-cache") |
        "secondmate \(.id): \(.state), \(.freshness // "unknown") (\(.provenance // "registered")) coverage - \(.reason // .doing // "state unavailable")"] +
      [$snap.omitted[]? | select(.surface | test("secondmate|showing|capped|truncated|unreadable|unavailable")) |
        "\(.surface); \(.reveal)"]) as $disclosures |

    "Topic \($t.name) briefing \($since | d10) to \($now | d10): \($landed | length) landed, \($answered | length) captain call(s) answered, \($newrows | length) new, \($heldetails | length) decision(s) open, \($flight | length) row(s) in flight." as $recapnext |

    {
      schema: "fm-topic-brief.v1",
      topic: {name: $t.name, aliases: $t.aliases, projects: $t.projects},
      generated: $now,
      window: {since: $since, until: $now, source: $since_source},
      labels_available: (($labels_note | length) == 0),
      recap: {generated: ($prev.generated // null), paragraph: ($prev.recap | if (. // "") == "" then null else . end)},
      changed_since: {
        landed: [$landed[] | {id, title, closed, owner, repo, pr_url: (prurl // null), report: reporturl}],
        new_rows: [$newrows[] | {id, title, created, state}],
        answered_decisions: [$answered[] | {id, title, closed}]
      },
      in_flight: $flight,
      decisions_open: [$heldetails[] | {
        id, title, owner, key: .task_id, repo,
        hold_reason: .hold_reason,
        hold_until: .hold_until,
        report: reporturl,
        options: (.hold_reason
          | if test("(^|[^[:alpha:]])options:") then
              (capture("(^|[^[:alpha:]])(?<opts>options:.*$)").opts
                | sub("^options:"; "")
                | [splits("\\|")]
                | map(gsub("^[ \\t]+|[ \\t]+$"; ""))
                | map(select(length > 0)))
            else [] end)
      }],
      next_steps: {
        ready: [$ready[] | {id, title, repo: (.repo // null)}],
        blocked: [$blocked[] | {id, title, repo, blocked_by: .blocked_by}]
      },
      timeline: $timeline,
      counts: {
        landed: ($landed | length),
        new_rows: ($newrows | length),
        answered: ($answered | length),
        in_flight: ($flight | length),
        decisions: ($heldetails | length),
        ready: ($ready | length),
        blocked: ($blocked | length)
      },
      disclosures: $disclosures,
      recap_next: $recapnext
    }'
}

# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------

topic_html_render() {
  # $1 = model file, $2 = output path. Self-contained page: inline CSS, inline
  # SVG timeline, small inline JS for the answers block; no external
  # resources; content readable with scripting disabled.
  #
  # Split of concerns: the page skeleton, CSS, and JS below are static bash
  # heredocs (no escaping hazards); jq renders only small per-row fragments
  # whose dynamic values are all esc()/attr()-escaped. Bash assembles the
  # final page by concatenation, so no HTML with quotes ever lives inside a
  # large jq string literal.
  local model="$1" out="$2" p="$TOPIC_TMP/htmlparts"
  mkdir -p "$p"

  jq -r -f <(cat <<'JQ'
    def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("'"; "&#39;");
    def attr: esc;
    def d10: ((. // "")[0:10]);
    . as $m |
    {
      topic_attr: ($m.topic.name | attr),
      window_line: (($m.window.since | d10) + " → " + ($m.window.until | d10) + " · generated " + ($m.generated | d10) + " · " + ($m.window.source | esc)),
      disclosures_lines: ([$m.disclosures[] | esc] | join("\n")),
      recap_para: (($m.recap.paragraph // "") | esc),
      recap_generated: (($m.recap.generated // "") | d10),
      landed_html: ([$m.changed_since.landed[] |
        "<div class=\"card\"><h3>\(.title | esc)</h3><p class=\"meta\">\(.id | esc) · closed \(.closed | d10)</p>" +
        (if (.pr_url // null) != null then "<p><a href=\"\(.pr_url | attr)\">\(.pr_url | esc)</a></p>" else "" end) +
        (if (.report // null) != null then "<p class=\"meta\">report: \(.report | esc)</p>" else "" end) +
        "</div>"] | join("\n")),
      new_html: ([$m.changed_since.new_rows[] |
        "<li><strong>\(.title | esc)</strong> <span class=\"meta\">\(.id | esc) · filed \(.created | d10)</span></li>"] | join("\n")),
      answered_html: ([$m.changed_since.answered_decisions[] |
        "<li><strong>\(.title | esc)</strong> <span class=\"meta\">\(.id | esc) · answered \(.closed | d10)</span></li>"] | join("\n")),
      flight_html: ([$m.in_flight[] |
        "<div class=\"card\"><h3>\(.name | esc)</h3><p class=\"meta\">\(.id | esc) · \(.kind | esc) · \(.state | esc)" +
        (if (.repo // null) != null then " · \(.repo | esc)" else "" end) +
        (if (.owner // "") != "(main)" then " · second mate" else "" end) +
        "</p>" +
        (if (.doing // "") != "" then "<p>\(.doing | esc)</p>" else "" end) +
        (if (.pr_url // null) != null then "<p><a href=\"\(.pr_url | attr)\">\(.pr_url | esc)</a></p>" else "" end) +
        "</div>"] | join("\n")),
      decisions_html: ([($m.decisions_open | to_entries[]) |
        .key as $i | .value as $d |
        "<div class=\"card decision\"><h3>\($d.title | esc)</h3><p class=\"meta\">\($d.id | esc)" +
        (if ($d.hold_until // null) != null then " · revisit by \($d.hold_until | d10)" else "" end) +
        "</p><p class=\"holdreason\">\($d.hold_reason | esc)</p>" +
        (if ($d.report // null) != null then "<p class=\"meta\">report: \($d.report | esc)</p>" else "" end) +
        "<fieldset class=\"opts\"><legend>Your answer</legend>" +
        ([$d.options | to_entries[] |
          "<label class=\"opt\"><input type=\"radio\" name=\"d\($i)\" value=\"\(.value | attr)\" data-decision=\"\($i)\"> \(.value | esc)</label>"] | join("")) +
        "<label class=\"opt\"><input type=\"radio\" name=\"d\($i)\" value=\"reconcile\" data-decision=\"\($i)\"> reconcile — re-check the records</label>" +
        "<label class=\"opt freeform\"><textarea name=\"t\($i)\" rows=\"2\" placeholder=\"or type your answer here\" data-freetext=\"\($i)\"></textarea></label>" +
        "</fieldset></div>"] | join("\n")),
      ready_html: ([$m.next_steps.ready[] |
        "<li><strong>\(.title | esc)</strong> <span class=\"meta\">\(.id | esc)" +
        (if (.repo // null) != null then " · \(.repo | esc)" else "" end) + "</span></li>"] | join("\n")),
      blocked_html: ([$m.next_steps.blocked[] |
        "<li><strong>\(.title | esc)</strong> <span class=\"meta\">\(.id | esc) · blocked by \(.blocked_by | join(", ") | esc)</span></li>"] | join("\n")),
      n_decisions: ($m.decisions_open | length),
      tl_svg:
        (if (($m.timeline | length) > 0) then
          (([$m.timeline[] | (.label | esc | length)] | max) * 7 + 170) as $w |
          (($m.timeline | length) * 34 + 24) as $h |
          ([($m.timeline | to_entries[]) |
            .key as $i | .value as $e |
            "<circle cx=\"26\" cy=\"\($i * 34 + 34)\" r=\"5\" class=\"dot \($e.kind | esc)\"/>" +
            "<text x=\"46\" y=\"\($i * 34 + 38)\" class=\"tl-label\">\($e.label | esc)</text>" +
            "<text x=\"8\" y=\"\($i * 34 + 22)\" class=\"tl-date\">\($e.date | d10)</text>" +
            "<text x=\"46\" y=\"\($i * 34 + 54)\" class=\"tl-id\">\(if ($e.id // null) != null then ($e.id | esc) else "" end)</text>"
           ] | join("")) as $tl |
          "<svg viewBox=\"0 0 \($w) \($h)\" width=\"\($w)\" class=\"timeline\" role=\"img\" aria-label=\"Topic timeline\" preserveAspectRatio=\"xMinYMin meet\"><line x1=\"26\" y1=\"20\" x2=\"26\" y2=\"\($h - 10)\" class=\"axis\"/>\($tl)</svg>"
        else "" end),
      aliases_line: (($m.topic.aliases | join(", ")) | esc),
      projects_line: (($m.topic.projects | join(", ")) | esc)
    }
JQ
  ) "$model" > "$p/parts.json" 2> "$p/jq.err" || {
    head -1 "$p/jq.err" >&2
    fail "HTML rendering failed for $out"
  }

  local part
  for part in topic_attr window_line disclosures_lines recap_para recap_generated landed_html new_html answered_html \
              flight_html decisions_html ready_html blocked_html n_decisions tl_svg aliases_line projects_line; do
    jq -j --arg k "$part" '.[$k]' "$p/parts.json" > "$p/$part.part"
  done

  local nd
  nd="$(cat "$p/n_decisions.part")"

  {
    cat <<'HEAD'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
HEAD
    printf '<title>Topic briefing: '
    printf '%s' "$(cat "$p/topic_attr.part")"
    printf '</title>\n'
    cat <<'CSS'
<style>
:root{--paper:#faf6ef;--ink:#22304a;--rust:#b34a3c;--navy:#22304a;--gold:#c8a44d;--line:#d8cfbd;--muted:#6b6455;--ok:#2e6b4f;}
*{box-sizing:border-box;max-width:100%}
body{margin:0;padding:16px;background:var(--paper);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;overflow-wrap:break-word;word-break:break-word}
main,header,footer{max-width:760px;margin:0 auto}
h1{font-size:1.5rem;margin:0 0 4px;color:var(--navy)}
h2{font-size:1.15rem;margin:1.6em 0 .4em;color:var(--navy);border-bottom:2px solid var(--line);padding-bottom:4px}
h3{font-size:1rem;margin:.2em 0}
.card{background:#fff;border:1px solid var(--line);border-left:4px solid var(--gold);border-radius:6px;padding:10px 12px;margin:10px 0}
.card.decision{border-left-color:var(--rust)}
.meta{color:var(--muted);font-size:.85rem;margin:.2em 0}
.muted{color:var(--muted);font-size:.9rem}
.disclosure{background:#fdf3d7;border:1px solid var(--gold);border-radius:6px;padding:6px 10px;font-size:.9rem}
.holdreason{white-space:pre-wrap;background:#f6f1e6;border-radius:6px;padding:8px 10px;margin:.5em 0;font-size:.95rem}
fieldset.opts{border:1px solid var(--line);border-radius:6px;padding:8px 10px;margin:.6em 0 0}
fieldset.opts legend{font-size:.85rem;color:var(--muted);padding:0 4px}
label.opt{display:block;padding:4px 2px}
textarea{width:100%;font:inherit;padding:6px;border:1px solid var(--line);border-radius:4px}
a{color:var(--rust);overflow-wrap:anywhere}
ul{padding-left:1.2em;margin:.4em 0}
li{margin:.35em 0}
.timeline{width:100%;height:auto;margin:8px 0}
.timeline .axis{stroke:var(--line);stroke-width:2}
.timeline .dot{fill:var(--gold)}
.timeline .dot.landed,.timeline .dot.closed{fill:var(--ok)}
.timeline .dot.answered{fill:var(--rust)}
.timeline .dot.briefing{fill:var(--navy)}
.timeline text{font:12px -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;fill:var(--ink)}
.timeline .tl-date{fill:var(--muted)}
.timeline .tl-id{fill:var(--muted)}
.answersbox{background:#fff;border:1px dashed var(--gold);border-radius:6px;padding:10px 12px;margin:14px 0}
#answers-line{white-space:pre-wrap;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.85rem;min-height:1.2em;margin:.4em 0}
button{font:inherit;background:var(--navy);color:#fff;border:none;border-radius:6px;padding:8px 14px;margin-top:8px;cursor:pointer}
footer{color:var(--muted);font-size:.8rem;margin-top:2.5em;border-top:1px solid var(--line);padding-top:10px}
</style>
</head>
CSS
    printf '<body data-topic="'
    printf '%s' "$(cat "$p/topic_attr.part")"
    cat <<'BODYOPEN'
">
<header>
BODYOPEN
    printf '<h1>Topic briefing: '
    printf '%s' "$(cat "$p/topic_attr.part")"
    printf '</h1>\n<p class="muted">'
    cat "$p/window_line.part"
    cat <<'HEADER'
</p>
HEADER
    if [ -s "$p/disclosures_lines.part" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && printf '<p class="disclosure">%s</p>\n' "$line"
      done < "$p/disclosures_lines.part"
    fi
    cat <<'MAINA'
</header>
<main>
MAINA
    if [ -s "$p/recap_para.part" ]; then
      printf '<section id="recap"><h2>Where we left off</h2><p>'
      cat "$p/recap_para.part"
      printf '</p><p class="muted">Previous briefing generated '
      cat "$p/recap_generated.part"
      printf '%s</p></section>\n' '.'
    fi
    printf '<section id="changed"><h2>Changed since</h2>\n'
    if [ -s "$p/landed_html.part" ]; then
      cat "$p/landed_html.part"
    else
      printf '<p class="muted">Nothing landed in this window.</p>\n'
    fi
    if [ -s "$p/new_html.part" ]; then
      printf '<h3>New rows</h3>\n<ul>\n'
      cat "$p/new_html.part"
      printf '</ul>\n'
    fi
    if [ -s "$p/answered_html.part" ]; then
      printf '<h3>Answered decisions</h3>\n<ul>\n'
      cat "$p/answered_html.part"
      printf '</ul>\n'
    fi
    cat <<'SECB'
</section>
<section id="flight"><h2>In flight</h2>
SECB
    if [ -s "$p/flight_html.part" ]; then
      cat "$p/flight_html.part"
    else
      printf '<p class="muted">Nothing in flight for this topic.</p>\n'
    fi
    cat <<'SECC'
</section>
<section id="decisions"><h2>Open captain decisions</h2>
SECC
    if [ -s "$p/decisions_html.part" ]; then
      cat "$p/decisions_html.part"
    else
      printf '<p class="muted">No open decisions for this topic.</p>\n'
    fi
    cat <<'ANSWBOX'
<div class="answersbox">
<h2 style="margin-top:0">Your answers</h2>
<p class="muted">Pick an option or type an answer per decision, then copy the answers line back into chat.</p>
<p>Answered <span id="ans-count">0</span>/
ANSWBOX
    printf '%s' "$nd"
    printf '</p>\n<pre id="answers-line">TOPIC-ANSWERS v1 | topic='
    printf '%s' "$(cat "$p/topic_attr.part")"
    printf ' | answered=0/%s</pre>\n' "$nd"
    cat <<'ANSWBOX3'
<button id="copy-answers" type="button">Copy answers</button>
ANSWBOX3
    printf '%s' '<noscript><p class="muted">With scripting disabled, answer in chat as: TOPIC-ANSWERS v1 | topic='
    printf '%s' "$(cat "$p/topic_attr.part")"
    printf ' | answered=&lt;n&gt;/%s | &lt;task-id&gt;=&lt;your answer&gt;</p></noscript>\n' "$nd"
    cat <<'SECD'
</div>
</section>
<section id="next"><h2>Next steps</h2>
SECD
    if [ -s "$p/ready_html.part" ]; then
      printf '<h3>Ready</h3>\n<ul>\n'
      cat "$p/ready_html.part"
      printf '</ul>\n'
    else
      printf '<p class="muted">Nothing ready.</p>\n'
    fi
    if [ -s "$p/blocked_html.part" ]; then
      printf '<h3>Blocked</h3>\n<ul>\n'
      cat "$p/blocked_html.part"
      printf '</ul>\n'
    fi
    cat <<'SECE'
</section>
<section id="timeline"><h2>Timeline</h2>
SECE
    if [ -s "$p/tl_svg.part" ]; then
      cat "$p/tl_svg.part"
    else
      printf '<p class="muted">No events in this window.</p>\n'
    fi
    cat <<'FOOT1'
</section>
</main>
<footer>
Generated from durable records only: the topic registry, the backlog ledger, the bearings snapshot, and this topic's briefing history.
FOOT1
    printf '%s' 'Aliases: '
    cat "$p/aliases_line.part"
    printf ' · Default projects: '
    cat "$p/projects_line.part"
    cat <<'FOOT2'
</footer>
<script>
(function(){
  "use strict";
  function sanitize(v){
    return v.replace(/\|/g, ";").replace(/[\r\n]+/g, " ");
  }
  function answerFor(i){
    var sel = document.querySelector('input[name="d'+i+'"]:checked');
    if (sel) return sel.value;
    var ta = document.querySelector('textarea[data-freetext="'+i+'"]');
    if (ta && ta.value.trim()) return sanitize(ta.value.trim());
    return null;
  }
  function refresh(){
    var parts = [];
    var n = 0;
    var cards = document.querySelectorAll(".decision");
    for (var i = 0; i < cards.length; i++){
      var meta = cards[i].querySelector(".meta");
      var id = meta ? meta.textContent.split(" ")[0] : null;
      var v = answerFor(i);
      if (v){ n = n + 1; if (id) parts.push(id + "=" + sanitize(v)); }
    }
    var line = "TOPIC-ANSWERS v1 | topic=" + document.body.getAttribute("data-topic") + " | answered=" + n + "/" + cards.length;
    if (parts.length) line = line + " | " + parts.join(" | ");
    document.getElementById("answers-line").textContent = line;
    document.getElementById("ans-count").textContent = String(n);
    return line;
  }
  document.addEventListener("change", function(event){
    var i = event.target.getAttribute("data-decision");
    if (i !== null){
      document.querySelector('textarea[data-freetext="'+i+'"]').value = "";
    }
    refresh();
  });
  document.addEventListener("input", function(event){
    var i = event.target.getAttribute("data-freetext");
    if (i !== null){
      document.querySelectorAll('input[name="d'+i+'"]').forEach(function(input){ input.checked = false; });
    }
    refresh();
  });
  document.getElementById("copy-answers").addEventListener("click", function(){
    var line = refresh();
    function fallback(){
      var ta = document.createElement("textarea");
      ta.value = line;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.left = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
    }
    if (navigator.clipboard && navigator.clipboard.writeText){
      navigator.clipboard.writeText(line).catch(fallback);
    } else {
      fallback();
    }
  });
})();
</script>
</body>
</html>
FOOT2
  } > "$out"
}

# ---------------------------------------------------------------------------
# Board
# ---------------------------------------------------------------------------

topic_board_payload() {
  # Compose an fm-bearings-board.v1 payload scoped to the topic. The board
  # build owns validation, reconcile injection, stale-card dropping, the
  # lavish session check, and the captured-answer binding by held task id.
  jq -n --slurpfile m "$TOPIC_TMP/model.json" '
    ($m[0]) as $m |
    def slug: gsub("[^A-Za-z0-9._-]"; "-") | .[0:64];
    {
      schema: "fm-bearings-board.v1",
      home: $m.topic.name,
      generated: $m.generated,
      prs_live: false,
      captains_call: [($m.decisions_open | to_entries[]) |
        .value as $d |
        ([$d.options | to_entries[] | {value: ("option-" + (.key | tostring) + "-" + (.value | slug)), label: .value}]) as $opts |
        ({ key: $d.key,
           type: "decision",
           repo: $d.repo,
           title: ($d.title | if (. // "") == "" then $d.id else . end),
           about: $d.hold_reason,
           options: $opts,
           allow_freeform: (($opts | length) == 0) }
         + (if (($opts | length) == 0) then {freeform_hint: "Type the captain answer as words; firstmate routes it by task id."} else {} end))],
      underway: [($m.in_flight[] |
        { id: .id,
          kind: ((.kind // "ship") | if (. // "") == "" then "ship" else . end),
          state: ((.state // "in_flight") | if (. // "") == "" then "in_flight" else . end),
          name: ((.name // .id) | if (. // "") == "" then .id else . end),
          doing: ((.doing // "") | if (. // "") == "" then (.state // "in_flight") else . end),
          repo: (.repo // null) })],
      landed: [($m.changed_since.landed[] |
        { id: .id,
          what: ((.title // "") | if (. // "") == "" then .id else . end),
          owner: .owner,
          repo: .repo }
        + (if ((.pr_url // null) != null) and ((.pr_url | test("^https://"))) then {pr_url: .pr_url} else {} end))],
      charted: ([($m.next_steps.ready[] | {id: .id, title: .title, repo: (.repo // null), reason: "ready", dispatchable: true})] +
                [($m.next_steps.blocked[] | {id: .id, title: .title, repo: (.repo // null), reason: ("blocked by " + (.blocked_by | join(", "))), dispatchable: false})]),
      warnings: $m.disclosures
    }'
}

topic_board_build() {
  local board_cmd="${FM_TOPIC_BOARD_CMD:-$SCRIPT_DIR/fm-bearings-board.sh}"
  "$board_cmd" build "$TOPIC_TMP/board.json" 2> "$TOPIC_TMP/board.err"
  local rc=$?
  if [ $rc -ne 0 ]; then
    printf 'fm-topic-brief: board build failed (exit %s)' "$rc" >&2
    [ -s "$TOPIC_TMP/board.err" ] && { printf ': ' >&2; head -3 "$TOPIC_TMP/board.err" | tr '\n' ' ' >&2; }
    printf '\n' >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Chat summary
# ---------------------------------------------------------------------------

topic_chat_summary() {
  jq -r '
    "topic: \(.topic.name)",
    "window: \(.window.since[0:10]) .. \(.window.until[0:10]) (\(.window.source))",
    (if .labels_available then "labels: available"
     else "labels: unavailable for one or more homes - see membership disclosures" end),
    "changed since: \(.counts.landed) landed, \(.counts.new_rows) new, \(.counts.answered) answered",
    (.changed_since.landed[] | "landed: \(.id) \(.title)\(if .pr_url != null then " " + .pr_url else "" end)"),
    "in flight: \(.counts.in_flight)\(if (.in_flight | length) > 0 then " - " + ([.in_flight[].name] | join("; ")) else "" end)",
    "decisions open: \(.counts.decisions)",
    (.decisions_open[] | "decision: \(.id) \(.hold_reason | split("Full context:")[0] | sub("(^|[^[:alpha:]])options:.*$"; "") | gsub("[[:space:]]+"; " ") | sub(" +$"; ""))\(if (.options | length) > 0 then " options: " + (.options | join(" | ")) else "" end)"),
    "next steps: \(.counts.ready) ready, \(.counts.blocked) blocked",
    (if ((.recap.paragraph // "") != "") then "recap: previous briefing \(.recap.generated[0:10])" else empty end),
    ([.disclosures[] | "note: \(.)"][]),
    (if $html_out != "" then "briefing: \($html_out)" else empty end),
    (if $board_built then "board: rebuilt with this topic only" else empty end)
  ' --arg html_out "$TOPIC_HTML_OUT" --argjson board_built "$TOPIC_BOARD_BUILT" "$1"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

TOPIC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fm-topic-brief.XXXXXX")"
trap 'rm -rf "$TOPIC_TMP"' EXIT

topic_registry_json
TOPIC_ENTRY="$(jq -ce --arg q "$TOPIC_QUERY" '
  (map(select(.name == $q)) | .[0]) //
  (map(select(.aliases | index($q))) | .[0]) //
  error("unknown topic")
' "$TOPIC_TMP/registry.json")" || fail "unknown topic: $TOPIC_QUERY (no name or alias matches; registered: $(jq -r 'map(.name) | join(", ")' "$TOPIC_TMP/registry.json"))"
TOPIC_NAME="$(printf '%s' "$TOPIC_ENTRY" | jq -r '.name')"
printf '%s' "$TOPIC_ENTRY" > "$TOPIC_TMP/entry.json"

# Window
TOPIC_PREV_FILE="$(topic_history_latest "$(topic_history_dir "$TOPIC_NAME")")"
printf '{"generated": null, "recap": ""}' > "$TOPIC_TMP/prev.json"
if [ -n "$TOPIC_PREV_FILE" ] && jq -e '(.generated | type) == "string"' "$TOPIC_PREV_FILE" >/dev/null 2>&1; then
  jq '{generated, recap: (.recap // "")}' "$TOPIC_PREV_FILE" > "$TOPIC_TMP/prev.json"
fi
if [ -n "$TOPIC_SINCE_FLAG" ]; then
  printf '%s' "$TOPIC_SINCE_FLAG" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    || fail "--since must be YYYY-MM-DD (got: $TOPIC_SINCE_FLAG)"
  jq -ne --arg date "$TOPIC_SINCE_FLAG" '$date + "T00:00:00Z" | fromdateiso8601 | strftime("%Y-%m-%d") == $date' >/dev/null 2>&1 \
    || fail "--since is not a real calendar date: $TOPIC_SINCE_FLAG"
  TOPIC_SINCE="$TOPIC_SINCE_FLAG"
  TOPIC_SINCE_SOURCE="flag"
elif [ -n "$TOPIC_PREV_FILE" ] && jq -e '.generated != null' "$TOPIC_TMP/prev.json" >/dev/null; then
  TOPIC_SINCE="$(jq -r '.generated' "$TOPIC_TMP/prev.json")"
  TOPIC_SINCE_SOURCE="previous-briefing"
else
  TOPIC_SINCE="$(jq -nr --arg now "$TOPIC_NOW" '$now | fromdateiso8601 - (14 * 86400) | todateiso8601')" \
    || fail "cannot compute the default 14-day window from $TOPIC_NOW"
  TOPIC_SINCE_SOURCE="default-14d"
fi

# Backlog rows (with the label-support probe and fallback)
TOPIC_LABELS_NOTE=""
TOPIC_HELD_NOTE=""
: > "$TOPIC_TMP/coverage.txt"
: > "$TOPIC_TMP/rows.ndjson"
topic_collect_rows "(main)" || fail "main backlog output could not be parsed"
if [ -f "$DATA/secondmates.md" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! secondmate_registry_parse_line "$line"; then
      printf '%s\n' 'secondmate registry contains an unreadable route; topic membership is incomplete' >> "$TOPIC_TMP/coverage.txt"
      continue
    fi
    topic_collect_rows "$SECONDMATE_REGISTRY_ID" || fail "secondmate backlog output could not be parsed"
  done < "$DATA/secondmates.md"
fi
jq -s 'add // []' "$TOPIC_TMP/rows.ndjson" > "$TOPIC_TMP/rows.json" || fail "cannot assemble backlog rows"

# Detail reads for held member rows (full title and hold reason; bounded)
: > "$TOPIC_TMP/details.ndjson"
HELD_TOTAL=0
while IFS="$(printf '\t')" read -r rid owner task_id; do
  [ -n "$rid" ] || continue
  HELD_TOTAL=$((HELD_TOTAL + 1))
  [ "$HELD_TOTAL" -le 20 ] || continue
  topic_tasks "$owner" show "$task_id" 2>> "$TOPIC_TMP/axi.err" | topic_toon_parse | jq -ce --arg id "$rid" '.[0] // empty | .id = $id' \
    >> "$TOPIC_TMP/details.ndjson" 2>> "$TOPIC_TMP/parse.err" || true
done < <(jq -r '.[] | select(.hold_kind == "captain" and .state != "done") | [.id, .owner, .task_id] | @tsv' "$TOPIC_TMP/rows.json")
if [ "$HELD_TOTAL" -gt 20 ]; then
  TOPIC_HELD_NOTE="only the first 20 held rows were detail-read; the rest fall back to list fields"
fi
jq -s '.' "$TOPIC_TMP/details.ndjson" > "$TOPIC_TMP/details.json" 2>/dev/null \
  || printf '[]' > "$TOPIC_TMP/details.json"

# Snapshot and model
topic_snapshot
topic_model > "$TOPIC_TMP/model.json" 2> "$TOPIC_TMP/model.err" || {
  printf 'fm-topic-brief: model assembly failed: ' >&2
  head -1 "$TOPIC_TMP/model.err" 2>/dev/null >&2
  printf '\n' >&2
  exit 2
}

# Outputs
if [ "$TOPIC_JSON" -eq 1 ]; then
  # --json prints the model only; the chat summary is the no-flag output.
  jq . "$TOPIC_TMP/model.json"
  exit 0
fi
TOPIC_BOARD_BUILT=false
if [ -n "$TOPIC_HTML_OUT" ]; then
  mkdir -p "$(dirname "$TOPIC_HTML_OUT")" || fail "cannot create output directory for $TOPIC_HTML_OUT"
  topic_html_render "$TOPIC_TMP/model.json" "$TOPIC_HTML_OUT" || fail "cannot publish HTML briefing: $TOPIC_HTML_OUT"
  topic_history_record "$(topic_history_dir "$TOPIC_NAME")" "$TOPIC_TMP/model.json"
fi
if [ "$TOPIC_BOARD" -eq 1 ]; then
  topic_board_payload > "$TOPIC_TMP/board.json" 2> "$TOPIC_TMP/board.err" || {
    printf 'fm-topic-brief: board payload composition failed: ' >&2
    head -1 "$TOPIC_TMP/board.err" 2>/dev/null >&2
    printf '\n' >&2
    exit 2
  }
  topic_board_build
  TOPIC_BOARD_BUILT=true
fi

topic_chat_summary "$TOPIC_TMP/model.json"
exit 0