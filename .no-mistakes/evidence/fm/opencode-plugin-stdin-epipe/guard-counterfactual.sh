#!/usr/bin/env bash
set -u
cd ~/.no-mistakes/worktrees/c75a534c6389/01M54HXZWEKVDYCYK19Q7245WW
CASE_DIR=$(mktemp -d "$PWD/.guard-base.XXXXXX")
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/.opencode/plugins/lib"
git show ce697402e662cd7f9d6ef5c367041dd51516eb49:.opencode/plugins/fm-primary-turnend-guard.js > "$CASE_DIR/.opencode/plugins/fm-primary-turnend-guard.js"
# Keep the helper fixed, isolating the guard writer as the only counterfactual.
cp .opencode/plugins/lib/fm-operational-input.js "$CASE_DIR/.opencode/plugins/lib/"
cp .opencode/plugins/package.json "$CASE_DIR/.opencode/plugins/"
printf 'Counterfactual: base guard writer with target operational-input helper\n'
FM_EPIPE_TEST_TMPDIR="$CASE_DIR" NODE_NO_WARNINGS=1 node ~/.no-mistakes/evidence/01M54HXZWEKVDYCYK19Q7245WW/child-outcomes.mjs "$CASE_DIR"
status=$?
if [ "$status" -eq 0 ]; then
  printf 'Base guard unexpectedly survived; race was not reproduced\n'
  exit 1
fi
printf 'Base guard crashed as expected (exit=%s); target survived 1000 calls with observed EPIPE.\n' "$status"
