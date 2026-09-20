#!/usr/bin/env bash
# fm-branch-shared-sync.sh - vendor the shared eligibility module into the
# Claude Code supervision-branch mod (docs/claude-supervision-branch.md).
#
# The generated file is .claude/mods/fm-branch-mod/lib/fm-branch-eligibility.ts:
# the pure v8 fold and eligible-rows scan of lib/fm-branch-eligibility.ts under
# a generated-file header, WITHOUT that file's thin node:fs default bindings -
# the hooks-module validator refuses any node:fs import in the module graph, so
# the mod binds the pure core through its host seam instead (hooks/branch.ts).
# Like the agent definition, the copy is a pure function of tracked files, so
# it is committed and regenerated only when lib/fm-branch-eligibility.ts or
# this script changes. tests/fm-branch-claude-mod.test.sh holds the committed
# copy to --check, and tests/fm-branch-eligibility.test.sh pins it equal to
# bash and the Pi extension on every fixture.
#
# Usage:
#   bin/fm-branch-shared-sync.sh          rewrite the vendored copy in place
#   bin/fm-branch-shared-sync.sh --check  exit 1 and name the file when it is stale
#   bin/fm-branch-shared-sync.sh --print  write the generated text to stdout only
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_TRACKED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$FM_TRACKED_ROOT/lib/fm-branch-eligibility.ts"
OUT="$FM_TRACKED_ROOT/.claude/mods/fm-branch-mod/lib/fm-branch-eligibility.ts"

generate() {
  # The vendored body is the source's pure section: everything up to (but not
  # including) the node:fs import, plus everything after it up to (but not
  # including) the thin-default-bindings marker. Anything else - a second
  # import, a moved marker - is a structural change this generator refuses to
  # guess around.
  [ "$(grep -c '^import { lstatSync, readdirSync, readFileSync } from "node:fs";$' "$SOURCE")" -eq 1 ] || {
    echo "fm-branch-shared-sync.sh: $SOURCE no longer carries exactly one node:fs import line; update this generator" >&2
    exit 1
  }
  [ "$(grep -c '^// ---- thin default bindings over node:fs' "$SOURCE")" -eq 1 ] || {
    echo "fm-branch-shared-sync.sh: $SOURCE no longer marks its node:fs bindings section; update this generator" >&2
    exit 1
  }
  cat <<'FM'
// GENERATED FILE - DO NOT EDIT BY HAND
// Vendored from lib/fm-branch-eligibility.ts by bin/fm-branch-shared-sync.sh:
// the pure v8 fold and eligible-rows scan only. The source file's thin
// node:fs default bindings are excluded because a hooks module may import
// only its own files by relative path and "claude-code"; the mod binds this
// core through its host seam instead (hooks/branch.ts scopeForUnreadWake).
// Regenerate with bin/fm-branch-shared-sync.sh.
FM
  awk '
    /^import { lstatSync, readdirSync, readFileSync } from "node:fs";$/ { next }
    /^\/\/ ---- thin default bindings over node:fs/ { exit }
    { print }
  ' "$SOURCE"
}

case "${1:-}" in
  --print)
    generate
    ;;
  --check)
    if ! generate | cmp -s - "$OUT"; then
      echo "stale: $OUT (run bin/fm-branch-shared-sync.sh)" >&2
      exit 1
    fi
    ;;
  '')
    mkdir -p "$(dirname "$OUT")"
    generate > "$OUT.tmp"
    mv -f "$OUT.tmp" "$OUT"
    ;;
  *)
    echo "usage: fm-branch-shared-sync.sh [--check|--print]" >&2
    exit 2
    ;;
esac
