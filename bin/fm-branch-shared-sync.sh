#!/usr/bin/env bash
# fm-branch-shared-sync.sh - vendor the shared supervision-branch modules into
# the Claude Code supervision-branch mod (docs/claude-supervision-branch.md).
#
# The generated files are the lib/fm-branch-*.ts modules the Pi extension and
# the mod's hooks/branch.ts must share, written under
# .claude/mods/fm-branch-mod/lib/ with a generated-file header:
#   - fm-branch-eligibility.ts: the pure v8 fold and eligible-rows scan of
#     lib/fm-branch-eligibility.ts WITHOUT that file's thin node:fs default
#     bindings - the hooks-module validator refuses any node:fs import in the
#     module graph, so the mod binds the pure core through its host seam
#     instead (hooks/branch.ts).
#   - fm-branch-report-sequence.ts and fm-branch-provider-latch.ts: verbatim
#     copies of the shared report/processed decision core and the
#     provider-error latch state machine, which are dependency-free by
#     contract (the generator refuses any node: import).
# Like the agent definition, each copy is a pure function of tracked files, so
# they are committed and regenerated only when a source or this script
# changes. tests/fm-branch-claude-mod.test.sh holds every committed copy to
# --check, and tests/fm-branch-report-sequence.test.sh pins the vendored
# copies byte-equal to the lib sources through the same decisions.
#
# Usage:
#   bin/fm-branch-shared-sync.sh          rewrite the vendored copies in place
#   bin/fm-branch-shared-sync.sh --check  exit 1 and name the file when one is stale
#   bin/fm-branch-shared-sync.sh --print [module]
#                                         write one module's generated text to stdout
#                                         only: the module named by its vendored file's
#                                         basename, or the original eligibility module
#                                         when no name is given
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_TRACKED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOD_LIB="$FM_TRACKED_ROOT/.claude/mods/fm-branch-mod/lib"

ELIGIBILITY_SOURCE="$FM_TRACKED_ROOT/lib/fm-branch-eligibility.ts"
REPORT_SEQUENCE_SOURCE="$FM_TRACKED_ROOT/lib/fm-branch-report-sequence.ts"
PROVIDER_LATCH_SOURCE="$FM_TRACKED_ROOT/lib/fm-branch-provider-latch.ts"

# The generated-file header for one vendored module. $1 is the source path
# relative to the repo root; $2 is the source-specific provenance note.
header() {
  cat <<FM
// GENERATED FILE - DO NOT EDIT BY HAND
// Vendored from $1 by bin/fm-branch-shared-sync.sh:
// $2
// Regenerate with bin/fm-branch-shared-sync.sh.
FM
}

generate_eligibility() {
  # The vendored body is the source's pure section: everything up to (but not
  # including) the node:fs import, plus everything after it up to (but not
  # including) the thin-default-bindings marker. Anything else - a second
  # import, a moved marker - is a structural change this generator refuses to
  # guess around.
  [ "$(grep -c '^import { lstatSync, readdirSync, readFileSync } from "node:fs";$' "$ELIGIBILITY_SOURCE")" -eq 1 ] || {
    echo "fm-branch-shared-sync.sh: $ELIGIBILITY_SOURCE no longer carries exactly one node:fs import line; update this generator" >&2
    exit 1
  }
  [ "$(grep -c '^// ---- thin default bindings over node:fs' "$ELIGIBILITY_SOURCE")" -eq 1 ] || {
    echo "fm-branch-shared-sync.sh: $ELIGIBILITY_SOURCE no longer marks its node:fs bindings section; update this generator" >&2
    exit 1
  }
  header "lib/fm-branch-eligibility.ts" "the pure v8 fold and eligible-rows scan only. The source file's thin
// node:fs default bindings are excluded because a hooks module may import
// only its own files by relative path and \"claude-code\"; the mod binds this
// core through its host seam instead (hooks/branch.ts scopeForUnreadWake)."
  awk '
    /^import { lstatSync, readdirSync, readFileSync } from "node:fs";$/ { next }
    /^\/\/ ---- thin default bindings over node:fs/ { exit }
    { print }
  ' "$ELIGIBILITY_SOURCE"
}

# A dependency-free shared module is vendored verbatim; the hooks validator
# refuses node: imports, so any such import in the source is a structural
# change this generator refuses to copy.
generate_pure_module() {
  local source=$1
  local provenance=$2
  if grep -q 'from "node:' "$source"; then
    echo "fm-branch-shared-sync.sh: $source must stay dependency-free but gained a node: import; update this generator" >&2
    exit 1
  fi
  header "${source#"$FM_TRACKED_ROOT"/}" "$provenance"
  cat "$source"
}

generate_report_sequence() {
  generate_pure_module "$REPORT_SEQUENCE_SOURCE" "the shared fm_branch_report / fm_branch_processed decision core
// (validation rules, task-in-scope rule, store-call argv, settlement order
// and failure meanings). The per-host refusal and failure strings are host
// seams declared in the source's header, not drift."
}

generate_provider_latch() {
  generate_pure_module "$PROVIDER_LATCH_SOURCE" "the shared provider-error latch state machine (counting,
// threshold, cooldowns, recovery probes). The failure predicate and the
// latch notifications are host seams declared in the source's header, not
// drift."
}

# source path -> generator name; one vendored file per shared module.
vendored_files() {
  printf '%s\n' \
    "$ELIGIBILITY_SOURCE:generate_eligibility:fm-branch-eligibility.ts" \
    "$REPORT_SEQUENCE_SOURCE:generate_report_sequence:fm-branch-report-sequence.ts" \
    "$PROVIDER_LATCH_SOURCE:generate_provider_latch:fm-branch-provider-latch.ts"
}

generate_one() {
  local spec=$1
  local source=${spec%%:*}
  local rest=${spec#*:}
  local generator=${rest%%:*}
  local outfile=$MOD_LIB/${rest#*:}
  "$generator" > "$outfile.tmp"
  mv -f "$outfile.tmp" "$outfile"
}

# Print one module's generated text to stdout. $1 is the vendored file's
# basename; anything else is a usage error.
print_one() {
  local want=$1 spec source rest generator
  while IFS= read -r spec; do
    rest=${spec#*:}
    generator=${rest%%:*}
    if [ "${rest#*:}" = "$want" ]; then
      "$generator"
      return 0
    fi
  done < <(vendored_files)
  echo "fm-branch-shared-sync.sh: unknown module '$want' (expected one of the vendored file basenames)" >&2
  return 2
}

case "${1:-}" in
  --print)
    if [ -n "${2:-}" ]; then
      print_one "$2"
    else
      print_one fm-branch-eligibility.ts
    fi
    ;;
  --check)
    status=0
    while IFS= read -r spec; do
      rest=${spec#*:}
      generator=${rest%%:*}
      outfile=$MOD_LIB/${rest#*:}
      if ! "$generator" | cmp -s - "$outfile"; then
        echo "stale: $outfile (run bin/fm-branch-shared-sync.sh)" >&2
        status=1
      fi
    done < <(vendored_files)
    exit $status
    ;;
  '')
    mkdir -p "$MOD_LIB"
    while IFS= read -r spec; do generate_one "$spec"; done < <(vendored_files)
    ;;
  *)
    echo "usage: fm-branch-shared-sync.sh [--check|--print [module]]" >&2
    exit 2
    ;;
esac
