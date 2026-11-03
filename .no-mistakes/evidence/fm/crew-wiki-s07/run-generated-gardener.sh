#!/usr/bin/env bash
# Exercise the emitted gardener instructions as an executable public contract.
set -eu
export FM_ROOT_OVERRIDE="$PWD"
export TMPDIR="$PWD/.wiki-live-tmp"
source <(sed '/^test_absent_config_keeps_gardener_verbs_silent$/,$d' tests/fm-wiki-gardener.test.sh)
bare=$(wiki_bare generated-report)
seed_checkout "$bare" "$TMP_ROOT/seed" >/dev/null
home=$(gardener_home_with_repo generated-report "$bare")
repo="$home/state/wiki/repo"
wiki_page "$repo/pages/tools/retire.md" 'retire this inactive page' 2026-07-04
wiki_usage_lesson "$repo" worker 2026-11-02 'used: tools/seed-page ok'
printf '## [2026-11-02] ingest | 1 lesson | 20261102T000000Z-testhost-testhome-worker-a1b2.md\n' >> "$repo/log.md"
wgit -C "$repo" add -A
wgit -C "$repo" commit -q -m 'wiki: supplied worker confirmation and inactive page'
wgit -C "$repo" push -q origin main
base=$(wgit -C "$repo" rev-parse HEAD)
task_copy="$TMP_ROOT/gardener task"
wgit -C "$repo" worktree add -q -b garden-report "$task_copy" HEAD
FM_HOME="$home" bash bin/fm-brief.sh garden-report crew-wiki --mode direct-push >/dev/null
brief="$home/data/garden-report/brief.md"
commands=$(wiki_brief_commands "$brief")
printf 'Commands emitted to the gardener:\n%s\n\n' "$commands"
printf 'Output from executing those commands in the linked task worktree:\n'
out=$(cd "$task_copy" && unset FM_HOME FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE && BASE="$base" bash -e -c "$commands" 2>&1)
printf '%s\n' "$out"
coverage=$(printf '%s\n' "$out" | grep '^wiki: coverage ')
expected='wiki: coverage pages=1 raw=2 pending=0 archived=1 usage-signals=1 usage-by-page={"tools/seed-page":1} stale-signals=0 unconfirmed90=0'
assert_equals "$expected" "$coverage" 'worked example: one confirmed live page, one retired page, two compiled raw lessons'
head=$(wgit -C "$task_copy" rev-parse HEAD)
line=$(python3 - "$brief" "$head" "$coverage" <<'PY'
import pathlib, re, sys
prompt = pathlib.Path(sys.argv[1]).read_text()
templates = re.findall(r"`(done \[at=<epoch>\]:[^`]+)`", prompt)
assert len(templates) == 1
print(templates[0].replace('<epoch>', '2').replace('{commit}', sys.argv[2]).replace('{coverage line}', sys.argv[3]))
PY
)
printf '\nCompleted gardener report:\n%s\n' "$line"
source bin/fm-dod-lib.sh
FM_HOME="$home" fm_dod_accept_ship_done ship direct-push "$task_copy" "$repo" "$line"
printf 'The real completion consumer accepted the report and its published commit.\n'
printf '\nPublished confirmed page:\n'
wgit --git-dir="$bare" show main:pages/tools/seed-page.md
printf '\nPublished archive:\n'
wgit --git-dir="$bare" show main:archive/pages/tools/retire.md
assert_contains "$(wgit --git-dir="$bare" show main:pages/tools/seed-page.md)" '> last-confirmed: 2026-11-02' 'the generated workflow applies worker confirmation'
wgit --git-dir="$bare" cat-file -e main:archive/pages/tools/retire.md
assert_equals '' "$(wgit -C "$repo" diff "$base" HEAD -- raw)" 'raw source records are unchanged'
printf '\nPASS: emitted gardener commands publish freshness changes, report exact coverage, and produce accepted completion.\n'
