#!/usr/bin/env bash
# Targeted public-interface checks. Fixtures and all Git remotes are disposable.
set -u
export FM_ROOT_OVERRIDE="$PWD"
export TMPDIR="$PWD/.wiki-live-tmp"
EVIDENCE=~/.no-mistakes/evidence/01M6FN2HH7F97G8FQDP2RM91A0
export EVIDENCE
source <(sed '/^test_absent_config_keeps_gardener_verbs_silent$/,$d' tests/fm-wiki-gardener.test.sh)
eval "$(declare -f run_wiki | sed '1s/run_wiki/run_wiki_original/')"
run_wiki() {
  local capture status
  capture=$(mktemp -d "$TMPDIR/capture.XXXXXX")
  run_wiki_original "$@" > "$capture/stdout" 2> "$capture/stderr"
  status=$?
  {
    printf '\nScenario: %s\n$ fm-wiki.sh ' "${CURRENT_SCENARIO:-manual}"
    printf '%q ' "${@:2}"
    printf '\n'
    cat "$capture/stdout" "$capture/stderr"
    printf '[exit %s]\n' "$status"
  } >> "$EVIDENCE/wiki-cli-transcript.txt"
  cat "$capture/stdout"
  cat "$capture/stderr" >&2
  rm -rf "$capture"
  return "$status"
}
scenarios=(
  test_publish_archives_pages_unconfirmed_for_120_days
  test_publish_refreshes_last_confirmed_from_usage_signals
  test_coverage_reports_pages_lessons_and_the_archive
  test_publish_ages_all_usage_verdicts_and_confirmation_dates
  test_usage_consumers_require_canonical_keys_and_generated_dates
  test_publish_rechecks_pruning_after_remote_usage
  test_publish_preserves_archive_link_destinations
  test_publish_preserves_untracked_notes_with_and_without_moves
  test_publish_and_lint_allow_zero_live_pages
  test_gardener_coverage_done_remains_terminal
  test_publish_refuses_a_raw_edit
  test_publish_refuses_a_foreign_page_commit
)
for CURRENT_SCENARIO in "${scenarios[@]}"; do
  printf '\nRunning %s\n' "$CURRENT_SCENARIO"
  "$CURRENT_SCENARIO"
done
# Keep generated/published outputs, rather than implementation text, as evidence.
for entry in 'pruneused:pages/tools/used-page.md' 'usageage:archive/pages/tools/old-ok.md' 'archivelinks:archive/pages/tools/old.md' 'archivelinks:README.md' 'private-notes-move:README.md' 'empty-pages:pages/tools/new.md'; do
  fixture=${entry%%:*}
  document=${entry#*:}
  {
    printf '\n--- Published %s (%s) ---\n' "$document" "$fixture"
    wgit --git-dir="$TMP_ROOT/$fixture.git" show "main:$document"
  } >> "$EVIDENCE/wiki-published-output.txt"
done
printf '\n--- Generated gardener completion ---\n' >> "$EVIDENCE/wiki-published-output.txt"
cat "$TMP_ROOT/coverage-done/state/garden-done.status" >> "$EVIDENCE/wiki-published-output.txt"
printf '\n--- Published wiki trees ---\n' >> "$EVIDENCE/wiki-published-output.txt"
for fixture in usageage private-notes-move empty-pages; do
  printf '\n%s\n' "$fixture" >> "$EVIDENCE/wiki-published-output.txt"
  wgit --git-dir="$TMP_ROOT/$fixture.git" ls-tree -r --name-only main >> "$EVIDENCE/wiki-published-output.txt"
done
printf '\nTargeted product checks complete.\n'
