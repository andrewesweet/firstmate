#!/usr/bin/env bash
# Load the existing gardener suite's definitions, then execute only due tests.
# No implementation-text assertions and no unrelated lint/publish tests run.
set -u
export FM_ROOT_OVERRIDE="$PWD"
lab_tmp=$(mktemp -d "$PWD/.wiki-due-existing.XXXXXX")
export TMPDIR="$lab_tmp" FM_TEST_TMPDIR="$lab_tmp"
# tests/lib.sh owns its EXIT trap; outer shell owns this enclosing directory.
(
  source <(awk '/^test_absent_config_keeps_gardener_verbs_silent$/ {exit} {print}' tests/fm-wiki-gardener.test.sh)
  fm_test_run \
    test_due_fires_at_25_uncompiled_lessons \
    test_due_fires_on_a_seven_day_old_lesson \
    test_due_counts_only_lessons_the_log_has_not_cited \
    test_due_counts_a_lesson_the_log_names_by_bare_id \
    test_due_keeps_a_prefix_of_a_logged_id_pending \
    test_due_reads_ids_separated_by_semicolons_and_commas \
    test_due_stays_quiet_while_a_gardener_task_is_open
)
status=$?
rm -rf "$lab_tmp"
exit "$status"
