#!/usr/bin/env bash
set -u
cd ~/.no-mistakes/worktrees/c75a534c6389/01M54HXZWEKVDYCYK19Q7245WW
RUN_TMP=$(mktemp -d "$PWD/.epipe-test.XXXXXX")
export TMPDIR="$RUN_TMP"
. tests/lib.sh
TMP_ROOT="$RUN_TMP/fixtures"
mkdir -p "$TMP_ROOT"
export NODE_NO_WARNINGS=1
trap 'fm_test_cleanup; rm -rf "$RUN_TMP"' EXIT
# Load executable test definitions without running the unrelated Pi/watch suite.
source <(awk '/^install_pi_watch_extension_fixture\(\)/ {copy=1} /^test_pi_extension_reports_external_healthy_watcher$/ {exit} copy {print}' tests/fm-pi-watch-extension.test.sh)
printf 'Runtime: '; node --version
printf '\nTarget commit: b6644086bfecb1d5e562fb056eb40dcf47963e14\n'
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
test_opencode_turnend_guard_survives_an_encoder_that_never_reads_stdin
printf '\nBase commit: ce697402e662cd7f9d6ef5c367041dd51516eb49 (expected regression failure)\n'
BASE_ROOT="$RUN_TMP/base"
mkdir -p "$BASE_ROOT/.opencode/plugins/lib"
for module in fm-primary-turnend-guard.js lib/fm-operational-input.js package.json; do
  git show "ce697402e662cd7f9d6ef5c367041dd51516eb49:.opencode/plugins/$module" > "$BASE_ROOT/.opencode/plugins/$module"
done
( ROOT="$BASE_ROOT"; test_opencode_turnend_guard_survives_an_encoder_that_never_reads_stdin )
base_status=$?
[ "$base_status" -ne 0 ] || { printf 'Base unexpectedly passed\n'; exit 1; }
printf 'Base failed as expected (status=%s); target passed.\n' "$base_status"
