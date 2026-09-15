#!/usr/bin/env bash
# PreCompact hook: record which skills this session had loaded before
# compaction voids the conversation that carried their bodies.
#
# Claude Code compaction (manual /compact and auto-compact) summarizes the
# conversation. AGENTS.md survives compaction - it travels in the system
# prompt - so every skill's load trigger survives, but a loaded skill's
# actual procedure lived only in the conversation and is summarized away with
# it. This hook fires before compaction from the tracked .claude/settings.json
# PreCompact entry, reads the hook payload's transcript_path, extracts every
# Skill tool_use `skill` value from that JSONL transcript, de-duplicates the
# names preserving first-load order, and writes them one per line to the
# $FM_HOME-resolved state/.compact-skills.
#
# The consuming side is bin/fm-session-start.sh's --reemit --source compact
# path: it prints the record as a loud COMPACTED SKILLS block (summaries
# void; re-load each skill at its next AGENTS.md trigger). Each PreCompact
# overwrites the record from the cumulative transcript. This script's header
# owns the record format; that digest path owns the print mechanics.
#
# Usage: fm-precompact-skills.sh
#   A Claude/Codex-shaped JSON hook payload on stdin. A missing, empty, or
#   unreadable transcript still writes an empty record: the next compaction
#   overwrites it, so an empty record is never a stale-list hazard.
#
# This hook must ALWAYS exit 0 and print nothing. A PreCompact exit 2 blocks
# compaction, and exit 0 stdout is appended to the compaction's own custom
# instructions, so any output here would reach the compacted session as
# instructions. A failed recording is exactly a compaction without a
# reminder - never a blocked compaction.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# A harness hook always pipes its payload; a terminal stdin (a manual
# invocation) is treated as an empty payload rather than blocking on a read.
PAYLOAD=
if [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
fi

# Same quote-split awk as fm-sessionstart-run.sh's `source` field: splitting
# on the quote character finds the key and its string value without jq, with
# the same escaped-quote limitation that precedent accepts. A value string's
# preceding segment ends with `:`; a key's does not.
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | awk '
  BEGIN { RS = "\"" }
  NR % 2 == 0 {
    if (prev ~ /:[[:space:]]*$/) {
      if (last == "transcript_path") { print; exit }
    } else {
      last = $0
    }
  }
  { prev = $0 }
' 2>/dev/null)

mkdir -p "$STATE" 2>/dev/null || true
TMP=$(mktemp "$STATE/.compact-skills.XXXXXX" 2>/dev/null) || TMP=
if [ -n "$TMP" ]; then
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # Per line (one JSON object each): split on quotes, so even records are
    # string contents and the record before each is its preceding segment.
    # A segment ending with `:` marks its string as a VALUE of the last key
    # seen; any other string is itself a key. `tool` remembers that the
    # current object is a Skill tool_use, so only its own `skill` value is
    # recorded, and first-load order plus `seen` give the de-duplication.
    awk '
      {
        last_key = ""; tool = ""
        n = split($0, parts, /"/)
        for (i = 2; i <= n; i += 2) {
          s = parts[i]
          if (parts[i - 1] ~ /:[[:space:]]*$/) {
            if (last_key == "name") {
              tool = (s == "Skill") ? "Skill" : ""
            } else if (last_key == "skill" && tool == "Skill" && s != "") {
              if (!(s in seen)) { seen[s] = 1; order[++count] = s }
              tool = ""
            }
          } else {
            last_key = s
          }
        }
      }
      END { for (i = 1; i <= count; i++) print order[i] }
    ' "$TRANSCRIPT" > "$TMP" 2>/dev/null || : > "$TMP"
  else
    : > "$TMP"
  fi
  mv -f "$TMP" "$STATE/.compact-skills" 2>/dev/null || rm -f "$TMP" 2>/dev/null || true
fi
exit 0
