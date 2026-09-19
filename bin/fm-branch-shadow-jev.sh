#!/usr/bin/env bash
# fm-branch-shadow-jev.sh - the TypeSafe (Jev) call shim for the Claude Code
# supervision-branch mod's shadow advisory trial (docs/claude-supervision-branch.md).
#
# Usage:
#   fm-branch-shadow-jev.sh
#       Read one complete TypeSafe System One request ({model, state, questions})
#       from stdin, POST it to https://api.typesafe.ai/v1/systemone, and print
#       exactly one JSON line on stdout:
#         success:    {"ok":true,"model":"jev-1.13.0","answers":{...}}
#         any failure: {"ok":false,"unavailable":"<short cause>","model":"jev"}
#       Exit 0 always; the caller records the unavailable result and moves on.
#       The shadow advisory never affects routing, so no failure here may
#       change the wake, the branch, or the report.
#
# Key discipline (identical to bin/fm-dispatch-resolve.sh): TYPESAFE_API_KEY is
# read from the environment, else through fmx_env_get from FM_HOME/.env into a
# private variable, and passed to curl only as an Authorization header on file
# descriptor 3. The key is never printed, logged, or put on argv, and
# TypeScript never reads it.
#
# Evidence boundary: this script forwards the request body it is given and
# nothing else. It never reads status logs, transcripts, or the environment
# beyond FM_HOME for the key.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TS_BASE=${TS_BASE:-https://api.typesafe.ai}
TS_TIMEOUT=${TS_TIMEOUT:-8}

unavailable() {
  printf '{"ok":false,"unavailable":%s,"model":"jev"}\n' "\"$(printf '%s' "$1" | head -c 200 | tr -d '"' | tr '\n' ' ')\""
  exit 0
}

command -v curl >/dev/null 2>&1 || unavailable "curl not found"
command -v jq >/dev/null 2>&1 || unavailable "jq not found"

REQUEST=$(cat)
[ -n "$REQUEST" ] || unavailable "empty request"
printf '%s' "$REQUEST" | jq -e 'has("state") and has("questions")' >/dev/null 2>&1 || unavailable "request lacks state/questions"

# ---- key: environment wins, else the home's .env, private variable only ------
KEY=${TYPESAFE_API_KEY:-}
if [ -z "$KEY" ]; then
  # shellcheck source=bin/fm-env-lib.sh
  . "$SCRIPT_DIR/fm-env-lib.sh"
  KEY=$(fmx_env_get TYPESAFE_API_KEY "${FM_HOME:?}/.env")
fi
[ -n "$KEY" ] || unavailable "key absent"
unset TYPESAFE_API_KEY

RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-branch-shadow-jev.XXXXXX") || unavailable "no temp file"
trap 'rm -f "$RESP_FILE"' EXIT
HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
  -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$KEY") \
  --data-binary @- 2>/dev/null) || HTTP=000
[ "$HTTP" = 200 ] || unavailable "http $HTTP"

# One JSON line out: model plus the answers object, validated just enough to
# be a record. Anything else is unavailable, never a partial answer.
jq -e -c '{ok: true, model: (.model // "jev"), answers: .answers} | select((.answers | type) == "object")' \
  "$RESP_FILE" 2>/dev/null || unavailable "malformed response"
