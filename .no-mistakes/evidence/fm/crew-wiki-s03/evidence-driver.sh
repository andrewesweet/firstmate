#!/usr/bin/env bash
set -eu
ROOT=$PWD
export FM_ROOT_OVERRIDE=$ROOT
export PATH=~/.no-mistakes/evidence/01M5TCVMDB06VFT51ANYBBV6BK/lychee-tools/lychee-x86_64-unknown-linux-gnu:$PATH
export TMPDIR=$ROOT/.test-gardener/tmp
EVIDENCE=~/.no-mistakes/evidence/01M5TCVMDB06VFT51ANYBBV6BK
# Load existing disposable-repository builders and behavioral cases, without
# executing the suite's entry point. Assertions execute the public CLI.
source <(sed '/^test_absent_config_keeps_gardener_verbs_silent$/,$d' tests/fm-wiki-gardener.test.sh)
set +e
run_wiki() {
  local home=$1 status output
  shift
  output=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$WIKI" "$@" 2>&1)
  status=$?
  {
    printf '\n$ fm-wiki.sh'; printf ' %q' "$@"; printf '\n'
    printf '%s\nexit=%s\n' "$output" "$status"
  } >> "$EVIDENCE/wiki-cli-transcript.txt"
  printf '%s' "$output"
  return "$status"
}
printf 'Real fm-wiki.sh against disposable local Git remotes; lychee 0.24.2.\n' > "$EVIDENCE/wiki-cli-transcript.txt"

# Independent boundary oracle: intent says at least 25, or at least 7 days.
bare=$(wiki_bare exact-boundary)
seed_checkout "$bare" "$TMP_ROOT/exact-seed" >/dev/null
home=$(gardener_home_with_repo exact-boundary "$bare")
repo=$home/state/wiki/repo
stamp=$(date -u +%Y%m%dT%H%M%SZ)
for i in $(seq 1 24); do add_raw "$repo" "$stamp" "boundary-$i" >/dev/null; done
wgit -C "$repo" add -A
wgit -C "$repo" commit -qm '24 fresh lessons'
out=$(run_wiki "$home" due); rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] || fail '24 fresh lessons must remain silent'
add_raw "$repo" "$stamp" boundary-25 >/dev/null
wgit -C "$repo" add -A
wgit -C "$repo" commit -qm '25th lesson'
out=$(run_wiki "$home" due) || fail '25 fresh lessons must schedule'
assert_contains "$out" '25 uncompiled' 'exact count boundary'
pass '24 remains quiet; 25 schedules'

for case in \
  test_absent_config_keeps_gardener_verbs_silent \
  test_non_gardener_roles_cannot_run_the_gardener_verbs \
  test_due_fires_on_a_seven_day_old_lesson \
  test_due_counts_only_lessons_the_log_has_not_cited \
  test_due_stays_quiet_while_a_gardener_task_is_open \
  test_due_includes_queued_backlog_tasks \
  test_lint_blocks_on_header_link_budget_and_citation_gaps \
  test_lint_blocks_over_budget_pages_and_indexes \
  test_lint_reports_advisories_without_blocking \
  test_lint_resolves_reference_links_and_excludes_code_examples \
  test_lint_includes_quoted_claims_and_checks_links_offline \
  test_index_regenerates_from_page_headers \
  test_publish_lands_pages_with_a_landing_proof \
  test_publish_refuses_a_raw_edit \
  test_publish_refuses_a_foreign_page_commit \
  test_publish_checks_foreign_commits_on_push_retries \
  test_publish_refuses_raw_changes_even_when_restored \
  test_publish_and_drain_refuse_other_effective_push_urls \
  test_idle_gardener_drains_discover_upstream_lessons \
  test_generated_gardener_commands_target_a_linked_worktree; do
  printf '\nSCENARIO: %s\n' "$case" >> "$EVIDENCE/wiki-cli-transcript.txt"
  "$case"
done

# Save the generated index as public output, including the shipped schema in
# this disposable wiki so it is checked in the same repository context.
cp assets/crew-wiki-AGENTS.md "$repo/AGENTS.md"
run_wiki "$home" index >/dev/null || fail 'final index generation'
cp "$repo/index.md" "$EVIDENCE/generated-index.md"
printf '\nSCHEMA: shipped template used as disposable wiki AGENTS.md.\n' >> "$EVIDENCE/wiki-cli-transcript.txt"

# Direct-push's emitted brief is an intentional generated worker interface.
printf '%s\n' '- crew-wiki [direct-push] - isolated test wiki' > "$home/data/projects.md"
FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" crew-wiki >> "$EVIDENCE/wiki-cli-transcript.txt" || fail 'direct-push registry resolution'
FM_HOME="$home" "$ROOT/bin/fm-brief.sh" evidence-g1 crew-wiki --mode direct-push >> "$EVIDENCE/wiki-cli-transcript.txt" || fail 'direct-push scaffold'
cp "$home/data/evidence-g1/brief.md" "$EVIDENCE/generated-direct-push-brief.md"
