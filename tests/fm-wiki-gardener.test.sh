#!/usr/bin/env bash
# Crew wiki slice 03 tests: the gardener compiles pages. Covers the four new
# fm-wiki.sh verbs (due, lint, index, publish) at their public interface, using
# bare-repository file:// remotes and temp FM_HOMEs the way slice 01 does.
# Slice 02 owns the mirror refresh in drain and the reader consult paragraph;
# nothing here touches those paths.

set -u

ROOT=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/jev-fake-helpers.sh
. "$ROOT/tests/jev-fake-helpers.sh"
WIKI="$ROOT/bin/fm-wiki.sh"

[ "$(lychee --version 2>/dev/null)" = 'lychee 0.24.2' ] || fail 'lychee 0.24.2 is required; install the official release binary from https://github.com/lycheeverse/lychee/releases/tag/lychee-v0.24.2 and put it on PATH'

TMP_ROOT=$(fm_test_tmproot fm-wiki-gardener)

# wiki_home <name>: one fake FM_HOME with config/, state/, data/, and a
# pinned HOME so nothing leaks into the developer's own home.
wiki_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/home"
  printf '%s\n' "$home"
}

# wiki_cfg <home> <role> <remote>: write config/wiki.
wiki_cfg() {
  local home=$1 role=$2 remote=$3
  printf 'remote=%s\n' "$remote" > "$home/config/wiki"
  printf 'role=%s\n' "$role" >> "$home/config/wiki"
}

# run_wiki <home> <args...>: run one wiki verb pinned to the fake home.
run_wiki() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" HOME="$home/home" \
    "$WIKI" "$@"
}

# wgit <args...>: git with a throwaway identity for fixture commits.
wgit() {
  git -c user.name=test -c user.email=test@example.test "$@"
}

# wiki_bare <name>: one fresh bare remote; echoes its path.
wiki_bare() {
  local bare="$TMP_ROOT/$1.git"
  git init -q --bare "$bare"
  printf '%s\n' "$bare"
}

# seed_checkout <bare> <dir>: clone the bare remote and seed a minimal valid
# wiki (schema files, one page, one cited raw lesson, an empty ingest log),
# committed and pushed to main. Echoes the checkout dir.
seed_checkout() {
  local bare=$1 dir=$2
  git clone -q "file://$bare" "$dir" 2>/dev/null || fail "seed clone failed"
  wgit -C "$dir" checkout -q -b main
  mkdir -p "$dir/pages/tools" "$dir/raw/2026/10"
  printf '# Crew wiki schema (fixture)\n' > "$dir/AGENTS.md"
  printf '# Crew wiki (fixture)\n' > "$dir/README.md"
  printf '# Crew wiki index\n' > "$dir/index.md"
  printf '## [2026-10-24] ingest | 1 lesson | 20261024T000000Z-testhost-testhome-seed-a1b2.md\n' > "$dir/log.md"
  cat > "$dir/pages/tools/seed-page.md" <<'EOF'
> summary: the seed page for gardener fixtures
> scope: tool:seed
> last-confirmed: 2026-10-24
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md
> aliases: seed

# Seed page

A body citing [lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md).
EOF
  cat > "$dir/raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md" <<'EOF'
---
wiki: raw-lesson v1
wiki-home: testhome
wiki-task: seed
wiki-final: done
date: 2026-10-24
---

## seed lesson
scope: tool:seed
claim: the seed lesson exists
evidence: this fixture
EOF
  wgit -C "$dir" add -A
  wgit -C "$dir" commit -q -m "wiki: seed fixture"
  wgit -C "$dir" push -q origin main || fail "seed push failed"
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main 2>/dev/null || fail "seed HEAD failed"
  printf '%s\n' "$dir"
}

# add_raw <repo> <stamp> <task>: one uncommitted raw lesson file; echoes it.
add_raw() {
  local repo=$1 stamp=$2 task=$3 dir file
  dir="$repo/raw/${stamp:0:4}/${stamp:4:2}"
  mkdir -p "$dir"
  file="$dir/${stamp}-testhost-testhome-${task}-a1b2.md"
  cat > "$file" <<EOF
---
wiki: raw-lesson v1
wiki-home: testhome
wiki-task: $task
wiki-final: done
date: 2026-10-25
---

## lesson $task
scope: tool:seed
claim: lesson $task exists
evidence: this fixture
EOF
  printf '%s\n' "$file"
}

gardener_home_with_repo() {  # <name> <bare>: gardener home cloned to the remote.
  local home bare
  home=$(wiki_home "$1")
  bare=$2
  wiki_cfg "$home" gardener "file://$bare"
  git clone -q "file://$bare" "$home/state/wiki/repo" 2>/dev/null || fail "gardener clone failed"
  printf '%s\n' "$home"
}

wiki_brief_commands() {
  python3 - "$1" <<'PYTHON'
import re
import sys
for line in open(sys.argv[1]):
    if line.startswith(("Run `", "Then run `")):
        for command in re.findall(r"`([^`]+)`", line):
            if "fm-wiki.sh " in command:
                print(command)
PYTHON
}

test_absent_config_keeps_gardener_verbs_silent() {
  local home out status
  home=$(wiki_home absent)
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "due with no config must exit non-zero"
  assert_equals '' "$out" "due without config prints nothing"
  out=$(run_wiki "$home" lint 2>&1) || fail "lint must exit 0 with no config"
  assert_equals '' "$out" "lint without config prints nothing"
  out=$(run_wiki "$home" index 2>&1) || fail "index must exit 0 with no config"
  assert_equals '' "$out" "index without config prints nothing"
  out=$(run_wiki "$home" publish --base HEAD 2>&1) || fail "publish must exit 0 with no config"
  assert_equals '' "$out" "publish without config prints nothing"
  pass "absent config/wiki leaves the gardener verbs silent"
}

test_non_gardener_roles_cannot_run_the_gardener_verbs() {
  local home out status
  home=$(wiki_home contrib)
  wiki_cfg "$home" contributor "file://$TMP_ROOT/contrib.git"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "due in a contributor home must exit non-zero"
  assert_equals '' "$out" "due in a contributor home prints nothing"
  for verb in lint index publish; do
    out=$(run_wiki "$home" $verb --base HEAD 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$verb in a contributor home must exit non-zero"
    assert_contains "$out" 'gardener' "$verb in a contributor home names the gardener-only restriction"
  done
  home=$(wiki_home reader)
  wiki_cfg "$home" reader "file://$TMP_ROOT/reader.git"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "due in a reader home must exit non-zero"
  assert_equals '' "$out" "due in a reader home prints nothing"
  out=$(run_wiki "$home" publish --base HEAD 2>&1) || fail "publish in a reader home must exit 0"
  assert_equals '' "$out" "publish in a reader home prints nothing"
  pass "only the gardener role runs the gardener verbs"
}

test_due_fires_at_25_uncompiled_lessons() {
  local home bare repo out i stamp
  bare=$(wiki_bare due25)
  seed_checkout "$bare" "$TMP_ROOT/due25-seed" >/dev/null
  home=$(gardener_home_with_repo due25 "$bare")
  repo="$home/state/wiki/repo"
  for i in $(seq 1 25); do
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    add_raw "$repo" "$stamp" "task-$i" >/dev/null
  done
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: 25 raw fixtures"
  out=$(run_wiki "$home" due 2>&1) || fail "due must exit 0 at 25 uncompiled lessons"
  assert_contains "$out" 'gardener due' "due names the gardener wait it reports"
  assert_contains "$out" '25' "due reports the uncompiled count"
  pass "due fires at 25 uncompiled lessons"
}

test_due_fires_on_a_seven_day_old_lesson() {
  local home bare repo out status
  bare=$(wiki_bare dueage)
  seed_checkout "$bare" "$TMP_ROOT/dueage-seed" >/dev/null
  home=$(gardener_home_with_repo dueage "$bare")
  repo="$home/state/wiki/repo"
  add_raw "$repo" 20200101T000000Z task-old >/dev/null
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: one old raw fixture"
  out=$(run_wiki "$home" due 2>&1) || fail "due must exit 0 when the oldest lesson is 7 days old"
  assert_contains "$out" 'gardener due' "due names the gardener wait it reports"
  # Three fresh lessons with an empty log stay quiet.
  bare=$(wiki_bare duequiet)
  seed_checkout "$bare" "$TMP_ROOT/duequiet-seed" >/dev/null
  home=$(gardener_home_with_repo duequiet "$bare")
  repo="$home/state/wiki/repo"
  for task in task-a task-b task-c; do
    add_raw "$repo" "$(date -u +%Y%m%dT%H%M%SZ)" "$task" >/dev/null
  done
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: three fresh raw fixtures"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "due must stay quiet below threshold with fresh lessons"
  assert_equals '' "$out" "a quiet due prints nothing"
  pass "due fires on age and stays quiet below threshold"
}

test_due_counts_only_lessons_the_log_has_not_cited() {
  local home bare repo out status cited
  bare=$(wiki_bare duecited)
  seed_checkout "$bare" "$TMP_ROOT/duecited-seed" >/dev/null
  home=$(gardener_home_with_repo duecited "$bare")
  repo="$home/state/wiki/repo"
  for task in task-a task-b; do
    add_raw "$repo" "$(date -u +%Y%m%dT%H%M%SZ)" "$task" >/dev/null
  done
  cited=$(basename "$(add_raw "$repo" "$(date -u +%Y%m%dT%H%M%SZ)" task-c)")
  printf '## [2026-10-25] ingest | 1 lesson | %s\n' "$cited" >> "$repo/log.md"
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: two pending plus one cited"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "due must stay quiet when only cited lessons remain"
  assert_equals '' "$out" "a cited lesson does not count toward due"
  pass "due counts only lessons the log has not cited"
}

test_due_counts_a_lesson_the_log_names_by_bare_id() {
  local home bare repo out status cited
  bare=$(wiki_bare duebare)
  seed_checkout "$bare" "$TMP_ROOT/duebare-seed" >/dev/null
  home=$(gardener_home_with_repo duebare "$bare")
  repo="$home/state/wiki/repo"
  cited=$(add_raw "$repo" 20200101T000000Z task-old)
  add_raw "$repo" "$(date -u +%Y%m%dT%H%M%SZ)" task-fresh >/dev/null
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: bare-id logged lesson plus one fresh"
  # Control: unlogged, the old lesson makes due fire on its age.
  out=$(run_wiki "$home" due 2>&1) || fail "due must fire while the old lesson is unlogged"
  assert_contains "$out" 'gardener due' "an unlogged old lesson makes due fire"
  # The log schema names bare raw ids (`assets/crew-wiki-AGENTS.md`); logging
  # the same lesson by bare id must silence the check. The seed log line keeps
  # the older `.md` form, and both forms count as compiled.
  printf '## [2026-10-25] ingest | 1 lesson | %s\n' "$(basename "$cited" .md)" >> "$repo/log.md"
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: log the old lesson by bare id"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "due must stay quiet when the log cites an old lesson by bare id"
  assert_equals '' "$out" "a lesson logged by bare id does not count toward due"
  pass "due honours a log line naming raw ids without .md"
}

test_due_keeps_a_prefix_of_a_logged_id_pending() {
  local home bare repo out status suffix pending compiled fresh_ids i stamp
  for suffix in '' .md; do
    bare=$(wiki_bare "dueprefix$suffix")
    seed_checkout "$bare" "$TMP_ROOT/dueprefix$suffix-seed" >/dev/null
    home=$(gardener_home_with_repo "dueprefix$suffix" "$bare")
    repo="$home/state/wiki/repo"
    pending=$(add_raw "$repo" 20200101T000000Z fix)
    compiled=$(add_raw "$repo" 20200101T000000Z fix-a1b2)
    fresh_ids=
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    for i in $(seq 1 24); do
      fresh_ids="$fresh_ids $(basename "$(add_raw "$repo" "$stamp" "fresh-$i")" .md)$suffix"
    done
    printf '## [2026-10-25] ingest | 1 lesson |\t%s%s\r\n' "$(basename "$compiled" .md)" "$suffix" >> "$repo/log.md"
    wgit -C "$repo" add -A
    wgit -C "$repo" commit -q -m "wiki: log only the longer raw id"
    out=$(run_wiki "$home" due 2>&1) || fail "a prefix collision must not suppress readiness"
    assert_equals 'wiki: gardener due (25 uncompiled raw lesson(s), oldest 2020-01-01)' "$out" "the prefix lesson still counts toward the 25-lesson threshold"
    printf '## [2026-10-25] ingest | 24 lessons |%s\n' "$fresh_ids" >> "$repo/log.md"
    wgit -C "$repo" add -A
    wgit -C "$repo" commit -q -m "wiki: compile the fresh lessons"
    out=$(run_wiki "$home" due 2>&1) || fail "the pending prefix lesson must still trigger readiness by age"
    assert_equals 'wiki: gardener due (1 uncompiled raw lesson(s), oldest 2020-01-01)' "$out" "only the old prefix lesson remains pending"
    printf '## [2026-10-25] ingest | 1 lesson | %s%s\n' "$(basename "$pending" .md)" "$suffix" >> "$repo/log.md"
    wgit -C "$repo" add -A
    wgit -C "$repo" commit -q -m "wiki: compile the prefix lesson"
    out=$(run_wiki "$home" due 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "due must stay quiet once every complete raw id is logged"
    assert_equals '' "$out" "all compiled lessons leave no pending readiness"
  done
  pass "due matches whole bare and legacy raw id tokens for count and age"
}

test_due_reads_ids_separated_by_semicolons_and_commas() {
  local home bare repo out status cited1 cited2 sepname sep
  for sepname in semi comma; do
    case $sepname in
      semi) sep='; ' ;;
      comma) sep=',' ;;
    esac
    bare=$(wiki_bare "duesep-$sepname")
    seed_checkout "$bare" "$TMP_ROOT/duesep-$sepname-seed" >/dev/null
    home=$(gardener_home_with_repo "duesep-$sepname" "$bare")
    repo="$home/state/wiki/repo"
    cited1=$(add_raw "$repo" 20200101T000000Z task-old1)
    cited2=$(add_raw "$repo" 20200101T000000Z task-old2)
    wgit -C "$repo" add -A
    wgit -C "$repo" commit -q -m "wiki: two unlogged old lessons"
    # Control: unlogged, the old lessons make due fire on their age.
    out=$(run_wiki "$home" due 2>&1) || fail "due must fire while the old lessons are unlogged"
    assert_contains "$out" 'gardener due' "an unlogged old lesson makes due fire"
    # The real gardener writes one ingest line per batch with the raw ids joined
    # by "; "; a separator-joined id must count as compiled like a bare token.
    printf '## [2026-10-25] ingest | 2 lessons | %s%s%s\n' \
      "$(basename "$cited1" .md)" "$sep" "$(basename "$cited2" .md)" >> "$repo/log.md"
    wgit -C "$repo" add -A
    wgit -C "$repo" commit -q -m "wiki: log both lessons in one separator-joined ingest line"
    out=$(run_wiki "$home" due 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "due must stay quiet when one ingest line lists both ids separated by$sep"
    assert_equals '' "$out" "separator-joined ids do not count toward due"
  done
  pass "due honours ingest lines separating raw ids with semicolons and commas"
}

test_due_stays_quiet_while_a_gardener_task_is_open() {
  local home bare repo out status i stamp
  bare=$(wiki_bare dueopen)
  seed_checkout "$bare" "$TMP_ROOT/dueopen-seed" >/dev/null
  home=$(gardener_home_with_repo dueopen "$bare")
  repo="$home/state/wiki/repo"
  for i in $(seq 1 25); do
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    add_raw "$repo" "$stamp" "task-$i" >/dev/null
  done
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: 25 raw fixtures"
  printf 'kind=ship\nproject=%s/crew-wiki\n' "$TMP_ROOT" > "$home/state/task-g1.meta"
  printf 'working [at=1]: gardening\n' > "$home/state/task-g1.status"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "due must stay quiet while a gardener task is open"
  assert_equals '' "$out" "an open gardener task keeps due quiet"
  printf 'done [at=2]: wiki pages published abc\n' > "$home/state/task-g1.status"
  out=$(run_wiki "$home" due 2>&1) || fail "due must fire once the gardener task is done"
  assert_contains "$out" 'gardener due' "a finished gardener task releases due"
  pass "due stays quiet while a gardener task is open"
}

test_lint_passes_a_well_formed_checkout() {
  local home bare repo out
  bare=$(wiki_bare lintok)
  seed_checkout "$bare" "$TMP_ROOT/lintok-seed" >/dev/null
  home=$(gardener_home_with_repo lintok "$bare")
  repo="$home/state/wiki/repo"
  out=$(run_wiki "$home" lint 2>&1) || fail "lint must exit 0 on the seeded checkout"
  assert_contains "$out" 'lint clean' "lint reports the clean verdict"
  pass "lint passes a well-formed checkout"
}

test_lint_blocks_on_header_link_budget_and_citation_gaps() {
  local home dir out status
  home=$(wiki_home lintbad)
  wiki_cfg "$home" gardener "file://$TMP_ROOT/lintbad.git"
  dir="$TMP_ROOT/lintbad-repo"
  mkdir -p "$dir/pages/tools" "$dir/raw/2026/10"
  printf '# index\n' > "$dir/index.md"
  printf 'x\n' > "$dir/raw/2026/10/20261025T000000Z-testhost-testhome-task-a-a1b2.md"
  # Missing summary header.
  cat > "$dir/pages/tools/bad.md" <<'EOF'
> scope: tool:seed
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261025T000000Z-testhost-testhome-task-a-a1b2.md

# Bad page

Body citing [lesson](../../raw/2026/10/20261025T000000Z-testhost-testhome-task-a-a1b2.md).
EOF
  out=$(run_wiki "$home" lint --repo "$dir" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "lint must block a page missing its summary header"
  assert_contains "$out" 'summary' "lint names the missing header field"
  # Fix the header, break a link.
  cat > "$dir/pages/tools/bad.md" <<'EOF'
> summary: a bad page
> scope: tool:seed
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261025T000000Z-testhost-testhome-task-a-a1b2.md

# Bad page

See [the missing page](missing.md) for details.
EOF
  out=$(run_wiki "$home" lint --repo "$dir" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "lint must block a dangling relative link"
  assert_contains "$out" 'missing.md' "lint names the dangling link"
  # Fix the link, drop every raw citation.
  cat > "$dir/pages/tools/bad.md" <<'EOF'
> summary: a bad page
> scope: tool:seed
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261025T000000Z-testhost-testhome-task-a-a1b2.md

# Bad page

No citations anywhere in this body.
EOF
  out=$(run_wiki "$home" lint --repo "$dir" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "lint must block a page whose claims cite no raw lesson"
  assert_contains "$out" 'cites no raw lesson' "lint names the citation gap"
  pass "lint blocks on header, link, and citation gaps"
}

test_lint_blocks_over_budget_pages_and_indexes() {
  local home dir out status i
  home=$(wiki_home lintbudget)
  wiki_cfg "$home" gardener "file://$TMP_ROOT/lintbudget.git"
  dir="$TMP_ROOT/lintbudget-repo"
  mkdir -p "$dir/pages/tools" "$dir/raw/2026/10"
  printf 'x\n' > "$dir/raw/2026/10/20261025T000000Z-testhost-testhome-task-a-a1b2.md"
  {
    printf '> summary: a long page\n> scope: tool:seed\n> last-confirmed: 2026-10-25\n'
    printf '> sources: raw/2026/10/20261025T000000Z-testhost-testhome-task-a-a1b2.md\n\n# Long\n\n'
    for i in $(seq 1 200); do printf 'filler line %s\n' "$i"; done
  } > "$dir/pages/tools/long.md"
  printf '# index\n' > "$dir/index.md"
  out=$(run_wiki "$home" lint --repo "$dir" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "lint must block a page over the 120-line budget"
  assert_contains "$out" '120' "lint names the page budget"
  printf '# ok\n' > "$dir/pages/tools/long.md"
  for i in $(seq 1 200); do printf -- '- [p%s](pages/tools/p%s.md) - s\n' "$i" "$i" >> "$dir/index.md"; done
  out=$(run_wiki "$home" lint --repo "$dir" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "lint must block an index over the 150-line budget"
  assert_contains "$out" '150' "lint names the index budget"
  pass "lint blocks over-budget pages and indexes"
}

test_lint_reports_advisories_without_blocking() {
  local home bare repo out
  bare=$(wiki_bare lintadv)
  seed_checkout "$bare" "$TMP_ROOT/lintadv-seed" >/dev/null
  home=$(gardener_home_with_repo lintadv "$bare")
  repo="$home/state/wiki/repo"
  # An orphan page: valid, cited, but linked from nowhere.
  cat > "$repo/pages/tools/orphan.md" <<'EOF'
> summary: an orphan page
> scope: tool:seed
> last-confirmed: 2026-10-24
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md

# Orphan

Body citing [lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md).
EOF
  out=$(run_wiki "$home" lint 2>&1) || fail "lint must exit 0 when only advisories fire"
  assert_contains "$out" 'advisory' "lint labels the non-blocking finding"
  assert_contains "$out" 'orphan.md' "lint names the orphan page"
  pass "lint reports advisories without blocking"
}

test_index_regenerates_from_page_headers() {
  local home bare repo out first second
  bare=$(wiki_bare indexgen)
  seed_checkout "$bare" "$TMP_ROOT/indexgen-seed" >/dev/null
  home=$(gardener_home_with_repo indexgen "$bare")
  repo="$home/state/wiki/repo"
  mkdir -p "$repo/pages/harnesses"
  cat > "$repo/pages/harnesses/pi-turnend.md" <<'EOF'
> summary: pi turn-end quirk
> scope: harness:pi
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md

# Pi turn-end

Body citing [lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md).
EOF
  printf 'stale hand-written index\n' > "$repo/index.md"
  out=$(run_wiki "$home" index 2>&1) || fail "index must exit 0"
  assert_contains "$out" 'index.md' "index reports the file it wrote"
  assert_contains "$(cat "$repo/index.md")" 'pi turn-end quirk' "the generated index carries the page summary"
  assert_contains "$(cat "$repo/index.md")" 'pages/harnesses/pi-turnend.md' "the generated index links the page path"
  assert_contains "$(cat "$repo/index.md")" 'seed page for gardener fixtures' "the generated index keeps every page"
  first=$(sha256sum "$repo/index.md" | cut -d' ' -f1)
  run_wiki "$home" index >/dev/null 2>&1 || fail "a second index run must exit 0"
  second=$(sha256sum "$repo/index.md" | cut -d' ' -f1)
  assert_equals "$first" "$second" "regenerating the index is idempotent"
  pass "index regenerates from page headers"
}

test_publish_lands_pages_with_a_landing_proof() {
  local home bare repo out base landed trailers
  bare=$(wiki_bare publishok)
  seed_checkout "$bare" "$TMP_ROOT/publishok-seed" >/dev/null
  home=$(gardener_home_with_repo publishok "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  cat > "$repo/pages/tools/gardened.md" <<'EOF'
> summary: a gardened page
> scope: tool:seed
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md

# Gardened

Body citing [lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md).
EOF
  printf '## [2026-10-25] ingest | 1 lesson | 20261024T000000Z-testhost-testhome-seed-a1b2.md\n' >> "$repo/log.md"
  out=$(run_wiki "$home" publish --base "$base" 2>&1) || fail "publish must exit 0: $out"
  assert_contains "$out" 'published' "publish reports the landing"
  landed=$(wgit -C "$bare" rev-parse main)
  trailers=$(wgit -C "$bare" show -s --format=%B main | git interpret-trailers --parse)
  assert_contains "$trailers" 'Wiki-Home: ' "publish retains home attribution"
  assert_contains "$trailers" 'Wiki-Host: ' "publish retains host attribution"
  assert_not_contains "$trailers" 'Wiki-Task: ' "publish carries no unused task attribution"
  assert_not_equals "$base" "$landed" "publish advances the remote main"
  wgit -C "$bare" ls-tree -r --name-only main -- pages/ | grep -q 'pages/tools/gardened.md' \
    || fail "the gardened page landed on the remote"
  wgit -C "$bare" show "main:index.md" | grep -q 'gardened page' \
    || fail "the remote index was regenerated with the new page"
  out=$(run_wiki "$home" publish --base "$landed" 2>&1) || fail "a clean republish must exit 0"
  assert_contains "$out" 'nothing to publish' "a run with no page changes reports it"
  pass "publish lands pages with a landing proof"
}

test_publish_refuses_a_raw_edit() {
  local home bare repo out base remote_before status
  bare=$(wiki_bare publishraw)
  seed_checkout "$bare" "$TMP_ROOT/publishraw-seed" >/dev/null
  home=$(gardener_home_with_repo publishraw "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  remote_before=$(wgit -C "$bare" rev-parse main)
  # A worktree raw addition plus a valid page change.
  add_raw "$repo" "$(date -u +%Y%m%dT%H%M%SZ)" task-evil >/dev/null
  cat > "$repo/pages/tools/gardened.md" <<'EOF'
> summary: a gardened page
> scope: tool:seed
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md

# Gardened

Body citing [lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md).
EOF
  out=$(run_wiki "$home" publish --base "$base" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "publish must refuse a raw edit"
  assert_contains "$out" 'raw' "the refusal names the raw path it protects"
  assert_equals "$remote_before" "$(wgit -C "$bare" rev-parse main)" "a refused publish pushes nothing"
  # A committed raw change after the base is refused the same way.
  rm -rf "$repo/raw/2026/10/"*task-evil*
  add_raw "$repo" "$(date -u +%Y%m%dT%H%M%SZ)" task-evil >/dev/null
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: evil raw edit"
  out=$(run_wiki "$home" publish --base "$base" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "publish must refuse a committed raw change after the base"
  assert_contains "$out" 'raw' "the committed refusal names the raw path"
  assert_equals "$remote_before" "$(wgit -C "$bare" rev-parse main)" "a refused publish pushes nothing"
  pass "publish refuses a raw edit"
}

test_publish_refuses_a_foreign_page_commit() {
  local home bare repo out base foreign other remote_before status
  bare=$(wiki_bare publishforeign)
  seed_checkout "$bare" "$TMP_ROOT/publishforeign-seed" >/dev/null
  home=$(gardener_home_with_repo publishforeign "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  # Someone else lands a page commit after our base.
  other="$TMP_ROOT/publishforeign-other"
  git clone -q "file://$bare" "$other" 2>/dev/null || fail "foreign clone failed"
  printf '\nForeign line.\n' >> "$other/pages/tools/seed-page.md"
  wgit -C "$other" commit -q -am "wiki: foreign page edit"
  wgit -C "$other" push -q origin main || fail "foreign push failed"
  foreign=$(wgit -C "$bare" rev-parse main)
  # Our own page change must not overwrite it.
  cat > "$repo/pages/tools/gardened.md" <<'EOF'
> summary: a gardened page
> scope: tool:seed
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md

# Gardened

Body citing [lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md).
EOF
  remote_before=$foreign
  out=$(run_wiki "$home" publish --base "$base" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "publish must refuse after a foreign page commit"
  assert_contains "$out" 'foreign' "the refusal names the foreign page commit"
  assert_equals "$remote_before" "$(wgit -C "$bare" rev-parse main)" "a refused publish pushes nothing"
  pass "publish refuses a foreign page commit"
}

test_due_includes_queued_backlog_tasks() {
  local home bare repo out status section backend
  bare=$(wiki_bare duequeued)
  seed_checkout "$bare" "$TMP_ROOT/duequeued-seed" >/dev/null
  home=$(gardener_home_with_repo duequeued "$bare")
  repo="$home/state/wiki/repo"
  add_raw "$repo" 20200101T000000Z task-old >/dev/null
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: pending lesson"
  for backend in manual tasks-axi; do
    printf '%s\n' "$backend" > "$home/config/backlog-backend"
    for section in Queued 'In flight'; do
      printf '## %s\n- [ ] garden-q1 - compile pending lessons (repo: crew-wiki)\n\n## Done\n' "$section" > "$home/data/backlog.md"
      out=$(run_wiki "$home" due 2>&1); status=$?
      [ "$status" -ne 0 ] || fail "due must suppress an open $backend backlog task in $section"
      assert_equals '' "$out" "open backlog task suppresses due silently"
    done
  done
  printf '## Queued\n- [ ] other-q1 - unrelated task (repo: crew-wiki-other)\n\n## Done\n- [x] garden-q1 - compiled (repo: crew-wiki)\n' > "$home/data/backlog.md"
  out=$(run_wiki "$home" due 2>&1) || fail "done and unrelated backlog tasks must release due: $out"
  pass "due includes queued and in-flight backlog tasks"
}

test_lint_requires_existing_raw_lesson_citations() {
  local home bare repo page out status source body
  bare=$(wiki_bare lintcitations)
  seed_checkout "$bare" "$TMP_ROOT/lintcitations-seed" >/dev/null
  home=$(gardener_home_with_repo lintcitations "$bare")
  repo="$home/state/wiki/repo"
  page="$repo/pages/tools/seed-page.md"
  for source in README.md raw/../../README.md raw/2026/10/missing.md; do
    printf '> summary: citation fixture\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\nKeep raw/ immutable.\n' "$source" > "$page"
    out=$(run_wiki "$home" lint 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "lint accepted an invalid source $source"
    assert_contains "$out" 'invalid raw lesson' "invalid header source blocks"
    assert_contains "$out" 'cites no raw lesson' "raw prose does not count as a citation"
  done
  source=raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md
  for body in 'Keep raw/ immutable.' '[missing](../../raw/2026/10/missing.md)' 'raw/2026/10/missing.md'; do
    printf '> summary: citation fixture\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n%s\n' "$source" "$body" > "$page"
    out=$(run_wiki "$home" lint 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "lint accepted a body without a real raw citation"
    assert_contains "$out" 'cites no raw lesson' "header alone does not support the body"
  done
  printf '> summary: citation fixture\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n[lesson](../../%s#seed) and [readme](../../README.md).\n' "$source" "$source" > "$page"
  out=$(run_wiki "$home" lint 2>&1) || fail "ordinary relative links and raw citations must pass: $out"
  pass "lint resolves raw citations and ordinary Markdown links"
}

test_uncited_advisory_ignores_ingest_logs_and_indexes() {
  local home bare repo lesson out
  bare=$(wiki_bare lintcoverage)
  seed_checkout "$bare" "$TMP_ROOT/lintcoverage-seed" >/dev/null
  home=$(gardener_home_with_repo lintcoverage "$bare")
  repo="$home/state/wiki/repo"
  lesson=$(add_raw "$repo" 20200101T000000Z uncited)
  printf '## [2020-01-02] ingest | 1 lesson | %s\n' "$(basename "$lesson")" >> "$repo/log.md"
  printf '%s\n' "${lesson#"$repo/"}" >> "$repo/index.md"
  printf '\nThe ingest record names %s.\n' "$(basename "$lesson")" >> "$repo/pages/tools/seed-page.md"
  out=$(run_wiki "$home" lint 2>&1) || fail "uncited advisory must not block lint: $out"
  assert_contains "$out" "raw lesson no page cites after 30 days: ${lesson#"$repo/"}" "ingest records do not count as page citations"
  printf '\nSource: [lesson](../../%s)\n' "${lesson#"$repo/"}" >> "$repo/pages/tools/seed-page.md"
  out=$(run_wiki "$home" lint 2>&1) || fail "citing the lesson must keep lint clean: $out"
  assert_not_contains "$out" 'raw lesson no page cites after 30 days:' "a page citation clears the advisory"
  pass "uncited lesson advisories consider pages only"
}

test_generated_gardener_commands_target_a_linked_worktree() {
  local home bare repo task_copy base brief commands out unchanged lesson status
  bare=$(wiki_bare linkedpublish)
  seed_checkout "$bare" "$TMP_ROOT/linkedpublish-seed" >/dev/null
  home=$(gardener_home_with_repo linkedpublish "$bare")
  repo="$home/state/wiki/repo"
  lesson=$(add_raw "$repo" 20200101T000000Z pending)
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: pending raw lesson"
  wgit -C "$repo" push -q origin main || fail "pending lesson push failed"
  out=$(run_wiki "$home" due 2>&1) || fail "pending lesson must make gardener due: $out"
  base=$(wgit -C "$repo" rev-parse HEAD)
  task_copy="$TMP_ROOT/linked task"
  wgit -C "$repo" worktree add -q -b garden-linked "$task_copy" HEAD || fail "linked task copy failed"
  printf '\nA compiled addition.\n' >> "$task_copy/pages/tools/seed-page.md"
  printf '## [2026-10-25] ingest | 1 lesson | %s\n' "$(basename "$lesson")" >> "$task_copy/log.md"
  unchanged=$(wgit -C "$repo" status --porcelain)
  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" garden-x1 crew-wiki --mode direct-push >/dev/null || fail "gardener brief failed"
  brief="$home/data/garden-x1/brief.md"
  assert_not_contains "$(cat "$brief")" 'no-mistakes doctor' "generated direct-push setup must not prescribe pipeline initialization"
  assert_not_contains "$(cat "$brief")" 'no-mistakes init' "generated direct-push setup must not initialize a pipeline"
  commands=$(wiki_brief_commands "$brief")
  [ "$(printf '%s\n' "$commands" | wc -l | tr -d ' ')" = 3 ] || fail "generated contract must deliver lint, index, publish commands"
  out=$(cd "$task_copy" && unset FM_HOME FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE && BASE="$base" bash -e -c "$commands" 2>&1) || fail "generated commands failed without inherited home settings: $out"
  assert_contains "$out" published "generated publish command lands the task copy"
  wgit -C "$bare" show main:pages/tools/seed-page.md | grep -q 'A compiled addition' || fail "task page change did not land"
  assert_equals "$(wgit -C "$bare" rev-parse main)" "$(wgit -C "$repo" rev-parse HEAD)" "scheduling clone advances to the proved landing"
  assert_equals "$unchanged" "$(wgit -C "$repo" status --porcelain)" "generated commands leave shared files untouched"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "published ingest log must suppress repeat scheduling"
  assert_equals '' "$out" "completed compilation leaves due silent"
  pass "generated commands publish a linked copy and refresh scheduling"
}

test_publish_checks_foreign_commits_on_push_retries() {
  local home bare repo other base out status kind hook marker remote_before
  for kind in pages raw; do
    bare=$(wiki_bare "race-$kind")
    seed_checkout "$bare" "$TMP_ROOT/race-$kind-seed" >/dev/null
    home=$(gardener_home_with_repo "race-$kind" "$bare")
    repo="$home/state/wiki/repo"
    base=$(wgit -C "$repo" rev-parse HEAD)
    other="$TMP_ROOT/race-$kind-other"
    git clone -q "file://$bare" "$other" 2>/dev/null || fail "race clone failed"
    if [ "$kind" = pages ]; then
      printf '\nA competing page change.\n' >> "$other/pages/tools/seed-page.md"
    else
      add_raw "$other" 20200101T000000Z competing-raw >/dev/null
    fi
    wgit -C "$other" add -A
    wgit -C "$other" commit -q -m "wiki: competing $kind change"
    remote_before=$(wgit -C "$other" rev-parse HEAD)
    hook="$repo/.git/hooks/pre-push"
    marker="$TMP_ROOT/race-$kind-fired"
    {
      printf '#!/usr/bin/env bash\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR\n'
      printf '[ -f %q ] && exit 0\n' "$marker"
      printf 'touch %q\n' "$marker"
      printf 'git -C %q push -q origin main\n' "$other"
    } > "$hook"
    chmod +x "$hook"
    printf '\nOur compiled addition.\n' >> "$repo/pages/tools/seed-page.md"
    out=$(run_wiki "$home" publish --base "$base" 2>&1); status=$?
    [ -f "$marker" ] || fail "push race never ran"
    if [ "$kind" = pages ]; then
      [ "$status" -ne 0 ] || fail "publish rebased a competing page commit on retry"
      assert_contains "$out" 'foreign page commit' "retry fetch enforces foreign-page refusal"
      assert_equals "$remote_before" "$(wgit -C "$bare" rev-parse main)" "refused retry leaves only the competing commit remote"
      assert_equals "$base" "$(wgit -C "$repo" merge-base HEAD "$remote_before")" "foreign page commit was never rebased into our branch"
    else
      [ "$status" -eq 0 ] || fail "raw-only race must allow rebase and publish: $out"
      wgit -C "$bare" show main:pages/tools/seed-page.md | grep -q 'Our compiled addition' || fail "retry failed to land compiled page"
      wgit -C "$bare" cat-file -e main:raw/2020/01/20200101T000000Z-testhost-testhome-competing-raw-a1b2.md || fail "retry lost the competing raw lesson"
    fi
  done
  pass "publish refuses competing page commits on retry and accepts raw-only advances"
}

test_publish_retries_its_own_unproved_landing() {
  local home bare repo base out status fakebin real_git marker landed other task_copy
  bare=$(wiki_bare publishunproved)
  seed_checkout "$bare" "$TMP_ROOT/publishunproved-seed" >/dev/null
  home=$(gardener_home_with_repo publishunproved "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  task_copy="$TMP_ROOT/proof-task"
  git clone -q "file://$bare" "$task_copy" 2>/dev/null || fail "proof task clone failed"
  other="$TMP_ROOT/proof-other"
  git clone -q "file://$bare" "$other" 2>/dev/null || fail "proof competing clone failed"
  add_raw "$other" 20200101T000000Z upstream-before-proof >/dev/null
  wgit -C "$other" add -A
  wgit -C "$other" commit -q -m "wiki: upstream raw addition"
  wgit -C "$other" push -q origin main || fail "proof raw push failed"
  printf '\nA compiled addition.\n' >> "$task_copy/pages/tools/seed-page.md"
  fakebin="$TMP_ROOT/proof-bin"
  marker="$TMP_ROOT/proof-fetch-failed"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # Positional parameters expand in the generated script.
    printf 'if [ "${3:-}" = fetch ] && [ "${6:-}" = main ] && [ ! -f %q ]; then\n' "$marker"
    printf '  touch %q; exit 1\nfi\n' "$marker"
    printf 'exec %q "$@"\n' "$real_git"
  } > "$fakebin/git"
  chmod +x "$fakebin/git"
  out=$(PATH="$fakebin:$PATH" run_wiki "$home" publish --repo "$task_copy" --base "$base" 2>&1); status=$?
  [ -f "$marker" ] || fail "landing-proof fetch failure was not injected"
  [ "$status" -ne 0 ] || fail "failed proof fetch must leave landing unproved"
  assert_contains "$out" unproved "publish reports the missing landing proof"
  landed=$(wgit -C "$bare" rev-parse main)
  assert_not_equals "$base" "$landed" "the first push landed before proof fetch failed"
  assert_equals "$base" "$(wgit -C "$repo" rev-parse HEAD)" "unproved publication leaves scheduling unchanged"
  out=$(run_wiki "$home" publish --repo "$task_copy" --base "$base" 2>&1) || fail "retry must accept this run's own landed commit: $out"
  assert_not_contains "$out" 'foreign page commit' "own commit is not foreign"
  assert_equals "$landed" "$(wgit -C "$bare" rev-parse main)" "retry does not create a duplicate commit"
  assert_equals "$landed" "$(wgit -C "$repo" rev-parse HEAD)" "no-op proof retry refreshes the scheduling clone"
  wgit -C "$bare" cat-file -e main:raw/2020/01/20200101T000000Z-testhost-testhome-upstream-before-proof-a1b2.md || fail "retry lost upstream raw lesson"
  pass "publish retries its own unproved landing after an upstream raw addition"
}

test_due_reads_adapter_backlogs_without_markdown() {
  local home bare repo out status fakebin state
  bare=$(wiki_bare dueadapter)
  seed_checkout "$bare" "$TMP_ROOT/dueadapter-seed" >/dev/null
  home=$(gardener_home_with_repo dueadapter "$bare")
  repo="$home/state/wiki/repo"
  add_raw "$repo" 20200101T000000Z adapter-pending >/dev/null
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: pending adapter lesson"
  printf 'backend = "beads"\n\n[beads]\npath = "graph/.beads"\n' > "$home/.tasks.toml"
  fakebin="$TMP_ROOT/adapter-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "$PWD" = "$FM_HOME" ] || exit 8
[ "$*" = 'list --repo crew-wiki' ] || exit 9
[ -z "${TASKS_AXI_FILE:-}" ] || exit 10
cat adapter-list
SH
  chmod +x "$fakebin/tasks-axi"
  for state in queued in_flight held; do
    printf 'tasks[1]{id,state,kind,repo,title}:\n  garden-q1,%s,ship,crew-wiki,Garden lessons\n' "$state" > "$home/adapter-list"
    out=$(TASKS_AXI_FILE="$TMP_ROOT/unrelated-backlog.md" PATH="$fakebin:$PATH" run_wiki "$home" due 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "adapter-backed $state gardener must suppress due"
    assert_equals '' "$out" "adapter-backed open gardener suppresses due silently"
  done
  printf 'tasks[1]{id,state,kind,repo,title}:\n  garden-q1,done,ship,crew-wiki,Garden lessons\n' > "$home/adapter-list"
  out=$(PATH="$fakebin:$PATH" run_wiki "$home" due 2>&1) || fail "closed adapter task must release due: $out"
  printf 'tasks[0]{id,state,kind,repo,title}:\n' > "$home/adapter-list"
  out=$(PATH="$fakebin:$PATH" run_wiki "$home" due 2>&1) || fail "empty adapter backlog must release due: $out"
  assert_absent "$home/data/backlog.md" "adapter-backed scheduling must not create a Markdown backlog"
  pass "due reads adapter task state without a Markdown backlog"
}

test_lint_checks_every_citation_and_parses_markdown_titles() {
  local home bare repo page source body title out status
  bare=$(wiki_bare lintallrefs)
  seed_checkout "$bare" "$TMP_ROOT/lintallrefs-seed" >/dev/null
  home=$(gardener_home_with_repo lintallrefs "$bare")
  repo="$home/state/wiki/repo"
  page="$repo/pages/tools/seed-page.md"
  source=raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md
  for title in '"source"' "'source'" '(source)' '"raw/missing.md"'; do
    printf '> summary: titled citation\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n[lesson](../../%s %s) and [readme](../../README.md "orientation").\n' "$source" "$source" "$title" > "$page"
    out=$(run_wiki "$home" lint 2>&1) || fail "valid Markdown title $title must pass: $out"
    assert_contains "$out" '1 raw lesson(s) cited' "titles and duplicate citations do not inflate coverage"
  done
  for body in "[lesson](../../$source) then [missing](../../raw/missing.md)" "[missing](../../raw/missing.md) then [lesson](../../$source)" "[lesson](../../$source) then [missing](../../raw/missing.md \"source\")"; do
    printf '> summary: mixed citations\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n%s\n' "$source" "$body" > "$page"
    out=$(run_wiki "$home" lint 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "one valid citation must not hide another missing citation"
    assert_contains "$out" 'raw/missing.md' "lint names the missing citation"
  done
  pass "lint validates every citation and separates Markdown destinations from titles"
}

test_publish_refuses_raw_changes_even_when_restored() {
  local home bare repo base out status kind raw
  for kind in edit delete add; do
    bare=$(wiki_bare "raw-history-$kind")
    seed_checkout "$bare" "$TMP_ROOT/raw-history-$kind-seed" >/dev/null
    home=$(gardener_home_with_repo "raw-history-$kind" "$bare")
    repo="$home/state/wiki/repo"
    base=$(wgit -C "$repo" rev-parse HEAD)
    raw=raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md
    case $kind in
      edit) printf '\nAn illegal edit.\n' >> "$repo/$raw" ;;
      delete) rm "$repo/$raw" ;;
      add) add_raw "$repo" 20200101T000000Z forbidden-history >/dev/null ;;
    esac
    wgit -C "$repo" add -A
    wgit -C "$repo" commit -q -m "wiki: forbidden raw $kind"
    if [ "$kind" = add ]; then
      rm "$repo/raw/2020/01/20200101T000000Z-testhost-testhome-forbidden-history-a1b2.md"
    else
      wgit -C "$repo" show "$base:$raw" > "$repo/$raw"
    fi
    wgit -C "$repo" add -A
    wgit -C "$repo" commit -q -m "wiki: restore raw tree"
    out=$(run_wiki "$home" publish --base "$base" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "publish must refuse restored raw $kind history"
    assert_contains "$out" 'run-owned commits changed files under raw/' "raw history is checked independently of final tree equality"
    assert_equals "$base" "$(wgit -C "$bare" rev-parse main)" "forbidden raw history never reaches remote"
  done
  pass "publish refuses raw edit, deletion, and addition history even after restoration"
}

test_publish_refreshes_scheduling_from_a_separate_clone() {
  local home bare repo task_copy base lesson out status
  bare=$(wiki_bare separatepublish)
  seed_checkout "$bare" "$TMP_ROOT/separatepublish-seed" >/dev/null
  home=$(gardener_home_with_repo separatepublish "$bare")
  repo="$home/state/wiki/repo"
  lesson=$(add_raw "$repo" 20200101T000000Z separate-pending)
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: pending separate lesson"
  wgit -C "$repo" push -q origin main || fail "separate lesson push failed"
  base=$(wgit -C "$repo" rev-parse HEAD)
  out=$(run_wiki "$home" due 2>&1) || fail "uncompiled separate lesson must make gardener due: $out"
  task_copy="$TMP_ROOT/separate-task"
  git clone -q "file://$bare" "$task_copy" 2>/dev/null || fail "separate task clone failed"
  printf '## [2026-10-25] ingest | 1 lesson | %s\n' "$(basename "$lesson")" >> "$task_copy/log.md"
  out=$(cd "$TMP_ROOT" && run_wiki "$home" publish --repo separate-task --base "$base" 2>&1) || fail "separate task publish failed: $out"
  assert_equals "$(wgit -C "$bare" rev-parse main)" "$(wgit -C "$repo" rev-parse HEAD)" "separate scheduling clone advances to proved commit"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "separate task publication must clear pending scheduling"
  assert_equals '' "$out" "completed separate compilation leaves due silent"
  out=$(run_wiki "$home" publish --repo "$task_copy" --base "$base" 2>&1) || fail "separate no-op publish must succeed: $out"
  assert_contains "$out" 'nothing to publish' "already landed separate compile remains idempotent"
  pass "publish refreshes scheduling from a separate clone"
}

test_lint_resolves_reference_links_and_excludes_code_examples() {
  local home bare repo page source body out status lesson
  bare=$(wiki_bare lintmarkdown)
  seed_checkout "$bare" "$TMP_ROOT/lintmarkdown-seed" >/dev/null
  home=$(gardener_home_with_repo lintmarkdown "$bare")
  repo="$home/state/wiki/repo"
  page="$repo/pages/tools/seed-page.md"
  source=raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md
  for body in '[lesson][src]' '[src][]' '[src]' '[lesson][ SRC ]'; do
    printf '> summary: reference citation\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n%s\n\n[src]: <../../%s#seed> "source"\n[unused]: missing.md\n' "$source" "$body" "$source" > "$page"
    out=$(run_wiki "$home" lint 2>&1) || fail "rendered reference citation $body must pass: $out"
    assert_contains "$out" '1 raw lesson(s) cited' "references resolve to the same raw lesson as inline citations"
  done
  for body in '[missing][ref]' '[ref][]' '[ref]'; do
    printf '> summary: dangling reference\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\nA real citation: [lesson](../../%s). Also %s.\n\n[ref]: missing.md\n' "$source" "$source" "$body" > "$page"
    out=$(run_wiki "$home" lint 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "lint must reject dangling reference $body"
    assert_contains "$out" 'missing.md' "all rendered reference forms validate their destinations"
  done
  lesson=$(add_raw "$repo" 20200101T000000Z only-in-code)
  {
    printf '> summary: code examples\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n[real][src]\n\n[src]: ../../%s\n\n' "$source" "$source"
    # shellcheck disable=SC2016 # Backticks are literal Markdown code delimiters.
    printf 'Inline `[fake](missing.md) raw/missing.md` and ``[fake](missing.md) ` raw/missing.md``.\n\n'
    # shellcheck disable=SC2016 # Backticks are literal Markdown code delimiters.
    printf '```markdown\n[fake](missing.md)\nraw/missing.md\n[fake-ref]: missing.md\n%s\n```\n\n' "${lesson#"$repo/"}"
    printf '~~~markdown\n[fake][fake-ref]\nraw/missing.md\n~~~\n\n'
    printf '    [fake](missing.md)\n    raw/missing.md\n\n'
    printf '> ~~~markdown\n> [fake](missing.md)\n> raw/missing.md\n> ~~~\n'
  } > "$page"
  out=$(run_wiki "$home" lint 2>&1) || fail "code examples must not create dangling links or citations: $out"
  assert_contains "$out" '1 raw lesson(s) cited' "code examples do not inflate citation counts"
  assert_contains "$out" "raw lesson no page cites after 30 days: ${lesson#"$repo/"}" "code-only raw paths do not suppress uncited advisories"
  for body in "\`$source\`" "\`\`$source\`\`"; do
    printf '> summary: code-only citation\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n%s\n' "$source" "$body" > "$page"
    out=$(run_wiki "$home" lint 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "inline code must not satisfy the body citation requirement"
    assert_contains "$out" 'cites no raw lesson' "code-only page remains uncited"
  done
  for body in '```' '~~~' '    '; do
    printf '> summary: block-code-only citation\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n' "$source" > "$page"
    if [ "$body" = '    ' ]; then
      printf '    %s\n' "$source" >> "$page"
    else
      printf '%s\n%s\n%s\n' "$body" "$source" "$body" >> "$page"
    fi
    out=$(run_wiki "$home" lint 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "code blocks must not satisfy the body citation requirement"
    assert_contains "$out" 'cites no raw lesson' "block-code-only page remains uncited"
  done
  printf '> summary: unused reference\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\nNo rendered citation.\n\n[src]: ../../%s\n' "$source" "$source" > "$page"
  out=$(run_wiki "$home" lint 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an unused definition must not count as a body citation"
  assert_contains "$out" 'cites no raw lesson' "unused reference definitions do not establish citations"
  pass "lint resolves rendered references and excludes code from all citation consumers"
}

test_gardener_verbs_reject_equals_form_options() {
  local home bare repo base out status verb
  bare=$(wiki_bare spacedoptions)
  seed_checkout "$bare" "$TMP_ROOT/spacedoptions-seed" >/dev/null
  home=$(gardener_home_with_repo spacedoptions "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  for verb in lint index publish; do
    out=$(run_wiki "$home" "$verb" "--repo=$repo" 2>&1); status=$?
    [ "$status" -eq 2 ] || fail "$verb must reject equals-form --repo"
    assert_contains "$out" "unknown $verb flag" "equals-form options report usage errors"
  done
  out=$(run_wiki "$home" publish --repo "$repo" "--base=$base" 2>&1); status=$?
  [ "$status" -eq 2 ] || fail "publish must reject equals-form --base"
  assert_contains "$out" 'unknown publish flag' "equals-form base reports a usage error"
  assert_equals "$base" "$(wgit -C "$bare" rev-parse main)" "rejected options do not publish anything"
  pass "gardener verbs retain spaced options and reject equals-form aliases"
}

test_idle_gardener_drains_discover_upstream_lessons() {
  local bare seed home repo out status i stamp remote_before lesson ids
  bare=$(wiki_bare idlerefresh)
  seed="$TMP_ROOT/idlerefresh-seed"
  seed_checkout "$bare" "$seed" >/dev/null
  home=$(gardener_home_with_repo idlerefresh "$bare")
  repo="$home/state/wiki/repo"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  ids=
  for i in $(seq 1 25); do
    lesson=$(add_raw "$seed" "$stamp" "upstream-$i")
    ids="$ids $(basename "$lesson")"
  done
  wgit -C "$seed" add -A
  wgit -C "$seed" commit -q -m "wiki: 25 incoming lessons"
  wgit -C "$seed" push -q origin main || fail "upstream lessons push failed"
  remote_before=$(wgit -C "$bare" rev-parse main)
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "due must not fetch upstream lessons itself"
  assert_equals '' "$out" "stale scheduling view remains silent before a drain"
  printf 'A local staged note.\n' >> "$repo/README.md"
  wgit -C "$repo" add README.md
  out=$(run_wiki "$home" drain-if-due 2>&1) || fail "idle gardener tick failed: $out"
  assert_contains "$out" 'nothing to publish' "empty gardener drain refreshes without publication"
  assert_equals "$remote_before" "$(wgit -C "$bare" rev-parse main)" "idle refresh never advances remote main"
  assert_equals "$remote_before" "$(wgit -C "$repo" rev-parse HEAD)" "idle gardener discovers the upstream commit"
  assert_contains "$(wgit -C "$repo" show :README.md)" 'A local staged note.' "idle refresh preserves staged local work"
  assert_equals README.md "$(wgit -C "$repo" diff --cached --name-only)" "idle refresh does not commit unrelated staged files"
  out=$(run_wiki "$home" due 2>&1) || fail "25 upstream lessons must make gardener due after refresh: $out"
  assert_contains "$out" '25 uncompiled' "incoming lessons reach the scheduling view"
  printf '## [2026-10-25] ingest | 25 lessons |%s\n' "$ids" >> "$seed/log.md"
  wgit -C "$seed" commit -q -am "wiki: compile incoming lessons"
  wgit -C "$seed" push -q origin main || fail "compiled log push failed"
  out=$(run_wiki "$home" drain 2>&1) || fail "idle direct refresh failed: $out"
  out=$(run_wiki "$home" due 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "upstream ingest log must clear scheduling after refresh"
  assert_equals '' "$out" "fully compiled upstream lessons leave due silent"
  home=$(wiki_home idlefirstclone)
  wiki_cfg "$home" gardener "file://$bare"
  add_raw "$seed" 20200101T000000Z upstream-old >/dev/null
  wgit -C "$seed" add -A
  wgit -C "$seed" commit -q -m "wiki: one old incoming lesson"
  wgit -C "$seed" push -q origin main || fail "old lesson push failed"
  remote_before=$(wgit -C "$bare" rev-parse main)
  out=$(run_wiki "$home" drain 2>&1) || fail "first idle clone failed: $out"
  out=$(run_wiki "$home" due 2>&1) || fail "first idle clone must discover an aged lesson: $out"
  assert_contains "$out" '1 uncompiled' "initial empty drain discovers upstream lesson age"
  assert_equals "$remote_before" "$(wgit -C "$bare" rev-parse main)" "initial empty drain pushes no commits"
  pass "idle gardener drains refresh upstream lessons and ingest logs without publishing local work"
}

test_idle_gardener_refresh_preserves_divergent_local_history() {
  local bare seed home repo local_head out
  bare=$(wiki_bare idlediverged)
  seed="$TMP_ROOT/idlediverged-seed"
  seed_checkout "$bare" "$seed" >/dev/null
  home=$(gardener_home_with_repo idlediverged "$bare")
  repo="$home/state/wiki/repo"
  printf '\nA local unlanded change.\n' >> "$repo/README.md"
  wgit -C "$repo" commit -q -am "wiki: local unlanded work"
  local_head=$(wgit -C "$repo" rev-parse HEAD)
  add_raw "$seed" 20200101T000000Z incoming-divergence >/dev/null
  wgit -C "$seed" add -A
  wgit -C "$seed" commit -q -m "wiki: incoming remote work"
  wgit -C "$seed" push -q origin main || fail "divergent fixture push failed"
  out=$(run_wiki "$home" drain 2>&1) || fail "divergent idle drain must remain nonfatal: $out"
  assert_contains "$out" 'cannot fast-forward' "idle refresh refuses to rewrite divergent history"
  assert_equals "$local_head" "$(wgit -C "$repo" rev-parse HEAD)" "idle refresh preserves unlanded commits"
  assert_not_equals "$local_head" "$(wgit -C "$bare" rev-parse main)" "idle refresh never pushes unlanded local work"
  pass "idle refresh preserves divergent local history"
}

test_gardener_commands_bind_custom_home_paths() {
  local home bare repo config state data task_copy base brief commands out rule
  bare=$(wiki_bare boundhome)
  seed_checkout "$bare" "$TMP_ROOT/boundhome-seed" >/dev/null
  home=$(wiki_home 'bound home')
  # shellcheck disable=SC2016 # The fixture path intentionally contains a literal dollar sign.
  config="$home/"'custom config $literal'
  state="$home/custom state"
  data="$home/custom data"
  mkdir -p "$config" "$state" "$data"
  printf 'remote=file://%s\nrole=gardener\n' "$bare" > "$config/wiki"
  repo="$state/wiki/repo"
  git clone -q "file://$bare" "$repo" 2>/dev/null || fail "custom state clone failed"
  task_copy="$TMP_ROOT/bound-task"
  wgit -C "$repo" worktree add -q -b garden-bound "$task_copy" HEAD || fail "custom task worktree failed"
  base=$(wgit -C "$repo" rev-parse HEAD)
  printf '\nA home-bound compilation.\n' >> "$task_copy/pages/tools/seed-page.md"
  (cd "$home" && FM_HOME=. FM_CONFIG_OVERRIDE='custom config $literal' \
    FM_STATE_OVERRIDE='custom state' FM_DATA_OVERRIDE='custom data' \
    bash "$ROOT/bin/fm-brief.sh" bound-x1 crew-wiki --mode direct-push >/dev/null) || fail "custom home brief failed"
  brief="$data/bound-x1/brief.md"
  commands=$(wiki_brief_commands "$brief")
  out=$(cd "$task_copy" && unset FM_HOME FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE && BASE="$base" bash -e -c "$commands" 2>&1) || fail "custom home commands failed without inherited settings: $out"
  assert_contains "$out" published "home-bound commands report actual publication"
  wgit -C "$bare" show main:pages/tools/seed-page.md | grep -q 'A home-bound compilation' || fail "home-bound command never published the task page"
  assert_present "$state/wiki/.drain.lock" "publication uses the supervising home's configured state path"
  assert_absent "$home/state/wiki" "publication must not substitute the home's default state path"
  # shellcheck disable=SC2016 # Python owns literal backticks; -c avoids Bash 3.2's nested-heredoc parsing.
  rule=$(python3 -c '
import re
import sys
for line in open(sys.argv[1]):
    if line.startswith("1. Never push"):
        for command in re.findall(r"`([^`]+)`", line):
            if "fm-wiki.sh publish " in command:
                print(command)
' "$brief")
  [ -n "$rule" ] || fail "home-bound safety rule did not provide its publication command"
  out=$(cd "$task_copy" && unset FM_HOME FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE && BASE="$base" bash -e -c "$rule --base \"\$BASE\"" 2>&1) || fail "home-bound safety-rule command failed: $out"
  assert_contains "$out" 'nothing to publish' "safety rule binds the same home as the Definition of done"
  pass "generated gardener commands bind absolute custom home paths without inherited settings"
}

test_idle_gardener_refresh_is_bounded_and_recovers() {
  local bare seed home repo base incoming fakebin real_git marker out before elapsed
  bare=$(wiki_bare idletimeout)
  seed="$TMP_ROOT/idletimeout-seed"
  seed_checkout "$bare" "$seed" >/dev/null
  home=$(gardener_home_with_repo idletimeout "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  add_raw "$seed" 20200101T000000Z idle-after-stall >/dev/null
  wgit -C "$seed" add -A
  wgit -C "$seed" commit -q -m "wiki: incoming lesson after stall"
  wgit -C "$seed" push -q origin main || fail "idle stall fixture push failed"
  incoming=$(wgit -C "$bare" rev-parse main)
  fakebin="$TMP_ROOT/idle-stall-bin"
  marker="$TMP_ROOT/idle-fetch-stalled"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # Positional parameters expand in the generated script.
    printf 'if [ "${3:-}" = fetch ]; then\n  touch %q\n  sleep 30\n  exit 1\nfi\n' "$marker"
    printf 'exec %q "$@"\n' "$real_git"
  } > "$fakebin/git"
  chmod +x "$fakebin/git"
  before=$(date +%s)
  out=$(FM_WIKI_DRAIN_CAP=2 PATH="$fakebin:$PATH" run_wiki "$home" drain 2>&1) || fail "stalled idle refresh must remain nonfatal: $out"
  elapsed=$(( $(date +%s) - before ))
  assert_present "$marker" "idle refresh reaches the bounded fetch boundary"
  [ "$elapsed" -le 7 ] || fail "idle fetch exceeded its drain budget ($elapsed seconds)"
  assert_equals "$base" "$(wgit -C "$repo" rev-parse HEAD)" "timed-out refresh preserves the last scheduling snapshot"
  assert_equals "$incoming" "$(wgit -C "$bare" rev-parse main)" "timed-out idle refresh publishes nothing"
  out=$(run_wiki "$home" drain 2>&1) || fail "idle refresh must recover after a stalled fetch: $out"
  assert_equals "$incoming" "$(wgit -C "$repo" rev-parse HEAD)" "next idle drain recovers incoming lessons"
  pass "idle gardener fetches stay bounded and recover on the next drain"
}

test_lint_and_publish_require_pinned_lychee() {
  local bare home repo base hidden fakebin out status verb mode
  bare=$(wiki_bare lycheerequired)
  seed_checkout "$bare" "$TMP_ROOT/lycheerequired-seed" >/dev/null
  home=$(gardener_home_with_repo lycheerequired "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  hidden=$(fm_test_base_path_sans "$PATH" lychee)
  fakebin="$TMP_ROOT/wrong-lychee-bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf "lychee 0.24.1\\n"\n' > "$fakebin/lychee"
  chmod +x "$fakebin/lychee"
  for mode in "$hidden" "$fakebin:$PATH"; do
    for verb in lint publish; do
      if [ "$verb" = publish ]; then
        out=$(PATH="$mode" run_wiki "$home" publish --base "$base" 2>&1); status=$?
      else
        out=$(PATH="$mode" run_wiki "$home" lint 2>&1); status=$?
      fi
      [ "$status" -ne 0 ] || fail "$verb must fail without lychee 0.24.2"
      assert_contains "$out" 'lychee 0.24.2 is required' "missing or wrong parser names the required version"
      assert_contains "$out" 'https://github.com/lycheeverse/lychee/releases/tag/lychee-v0.24.2' "parser error provides installation instructions"
      assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one parser error stops the command"
      assert_equals "$base" "$(wgit -C "$repo" rev-parse HEAD)" "missing parser cannot commit pages"
    done
  done
  pass "lint and publish require the exact parser version with one actionable error"
}

test_lint_includes_quoted_claims_and_checks_links_offline() {
  local bare home repo page source out status body
  bare=$(wiki_bare lintquotes)
  seed_checkout "$bare" "$TMP_ROOT/lintquotes-seed" >/dev/null
  home=$(gardener_home_with_repo lintquotes "$bare")
  repo="$home/state/wiki/repo"
  page="$repo/pages/tools/seed-page.md"
  source=raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md
  for body in "> A quoted [lesson](../../$source)." "> > [quoted][src]"; do
    printf '> summary: quoted claim\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\n%s\n\n[src]: ../../%s "source"\n\n[external](http://127.0.0.1:1/never-connect)\n' "$source" "$body" "$source" > "$page"
    out=$(run_wiki "$home" lint 2>&1) || fail "quoted citations and unreachable external links must pass offline: $out"
    assert_contains "$out" '1 raw lesson(s) cited' "quoted citations count as page coverage"
  done
  printf '> A missing [lesson](../../raw/missing.md).\n' >> "$page"
  out=$(run_wiki "$home" lint 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "another valid citation cannot hide a missing quoted link"
  assert_contains "$out" 'missing.md' "quoted dangling links remain blocking"
  printf '> summary: [header citation](../../%s)\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: %s\n\nNo body citation.\n' "$source" "$source" > "$page"
  out=$(run_wiki "$home" lint 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "rendered metadata links cannot substitute for body citations"
  assert_contains "$out" 'cites no raw lesson' "metadata stays separate from body coverage"
  printf 'raw fixture\n' > "$repo/raw/2026/10/space (lesson).md"
  printf '> summary: parser syntax\n> scope: tool:seed\n> last-confirmed: 2026-10-24\n> sources: raw/2026/10/space (lesson).md\n\n[lesson](<../../raw/2026/10/space (lesson).md> "source")\n' > "$page"
  out=$(run_wiki "$home" lint 2>&1) || fail "Markdown destinations with spaces and parentheses must pass: $out"
  assert_contains "$out" '1 raw lesson(s) cited' "resolved destinations identify existing raw lessons"
  pass "quoted claims, metadata, complex destinations, and offline links use one parser"
}

test_publish_and_drain_refuse_other_effective_push_urls() {
  local verb mode bare other home repo base out status queued urls
  for verb in publish drain; do
    for mode in single multiple rewrite; do
      bare=$(wiki_bare "pushurl-$verb-$mode")
      other=$(wiki_bare "pushurl-other-$verb-$mode")
      seed_checkout "$bare" "$TMP_ROOT/pushurl-seed-$verb-$mode" >/dev/null
      home=$(gardener_home_with_repo "pushurl-$verb-$mode" "$bare")
      repo="$home/state/wiki/repo"
      base=$(wgit -C "$repo" rev-parse HEAD)
      case $mode in
        single) wgit -C "$repo" config remote.origin.pushurl "file://$other" ;;
        multiple)
          wgit -C "$repo" config --add remote.origin.pushurl "file://$bare"
          wgit -C "$repo" config --add remote.origin.pushurl "file://$other"
          ;;
        rewrite) wgit -C "$repo" config "url.file://$other.pushInsteadOf" "file://$bare" ;;
      esac
      urls=$(wgit -C "$repo" remote get-url --push --all origin)
      assert_contains "$urls" "file://$other" "fixture redirects at least one effective push URL"
      if [ "$verb" = publish ]; then
        printf '\nA private compiled claim.\n' >> "$repo/pages/tools/seed-page.md"
        out=$(run_wiki "$home" publish --base "$base" 2>&1); status=$?
        [ "$status" -ne 0 ] || fail "publish must refuse $mode push redirection"
      else
        mkdir -p "$home/state/wiki/outbox"
        queued="$home/state/wiki/outbox/20261025T000000Z-testhost-testhome-pushurl-a1b2.md"
        printf 'private raw lesson\n' > "$queued"
        out=$(run_wiki "$home" drain 2>&1) || fail "drain refusal remains best effort"
        [ -f "$queued" ] || fail "refused drain must keep the lesson queued"
      fi
      assert_contains "$out" 'effective origin push URL' "both publishers explain the destination refusal"
      assert_equals "$base" "$(wgit -C "$bare" rev-parse main)" "preflight prevents even the approved URL from receiving a multi-push"
      [ -z "$(wgit -C "$other" for-each-ref --format='%(refname)')" ] || fail "private wiki history reached an unapproved remote"
      assert_equals "$base" "$(wgit -C "$repo" rev-parse HEAD)" "destination refusal precedes local commits"
    done
  done
  pass "both publishers reject alternate, multiple, and rewritten push destinations before uploading"
}

# --- slice 04: Jev triage, calibration report, contradiction candidates -----

# triage_fixture <name> [extra]: a plain wiki checkout for the triage verb with
# one pending raw lesson (alpha, scope tool:firstmate), plus a second pending
# lesson (beta, scope fleet:routing) when `extra` is non-empty. It needs no git
# repository: triage reads files. Echoes the checkout directory.
triage_fixture() {
  local dir="$TMP_ROOT/$1-repo" extra=${2:-}
  mkdir -p "$dir/pages/tools" "$dir/pages/fleet" "$dir/raw/2026/10"
  printf '# Crew wiki index\n' > "$dir/index.md"
  printf '## [2026-10-24] ingest | 1 lesson | 20261024T000000Z-testhost-testhome-seed-a1b2\n' > "$dir/log.md"
  cat > "$dir/raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md" <<'EOF'
---
wiki: raw-lesson v1
wiki-home: testhome
wiki-task: seed
wiki-final: done
date: 2026-10-24
---

## seed lesson
scope: tool:seed
claim: the seed lesson exists
evidence: this fixture
EOF
  cat > "$dir/pages/tools/firstmate.md" <<'EOF'
> summary: firstmate tooling craft
> scope: tool:firstmate
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md

# Firstmate tooling

The seed lesson exists ([lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md)).
EOF
  cat > "$dir/pages/fleet/routing.md" <<'EOF'
> summary: dispatch routing craft
> scope: fleet:routing
> last-confirmed: 2026-10-25
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md

# Routing

The seed lesson exists ([lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md)).
EOF
  cat > "$dir/raw/2026/10/20261025T010000Z-testhost-testhome-alpha-b1c2.md" <<'EOF'
---
wiki: raw-lesson v1
wiki-home: testhome
wiki-task: alpha
wiki-final: done
date: 2026-10-25
---

## firstmate test runner runs changed files
scope: tool:firstmate
claim: the firstmate test runner only runs changed test files locally
evidence: ran bin/fm-test-run.sh --changed
EOF
  if [ -n "$extra" ]; then
    cat > "$dir/raw/2026/10/20261025T020000Z-testhost-testhome-beta-d3e4.md" <<'EOF'
---
wiki: raw-lesson v1
wiki-home: testhome
wiki-task: beta
wiki-final: done
date: 2026-10-25
---

## dispatch routes by scope
scope: fleet:routing
claim: dispatch routes work by secondmate scope registry
evidence: saw the routing rule
EOF
  fi
  printf '%s\n' "$dir"
}

# triage_home <name>: gardener home with no clone; --repo carries the checkout.
triage_home() {
  local home
  home=$(wiki_home "$1")
  wiki_cfg "$home" gardener "file://$TMP_ROOT/$1.git"
  printf '%s\n' "$home"
}

# plan_query <plan> <python expression over plan>: one value from a written plan.
plan_query() {
  python3 - "$1" "$2" <<'PYPLAN'
import json
import sys

plan = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"plan": plan}))
PYPLAN
}

test_triage_writes_an_unannotated_plan_with_jev_off() {
  local home repo plan fake out
  repo=$(triage_fixture off extra)
  home=$(triage_home triage-off)
  plan="$home/data/gardener/plan.json"
  fake=$(fm_fakebin "$TMP_ROOT/triage-off")
  fm_fake_jev "$fake"
  # The fake would answer, but the flag is this process's gate: unset means no
  # call at all, so the plan is complete and unannotated.
  out=$(FM_FAKE_JEV_LOG="$TMP_ROOT/triage-off/calls" run_wiki "$home" triage --repo "$repo" 2>&1) \
    || fail "triage must exit 0 with the flag off: $out"
  assert_contains "$out" 'jev off' "the triage line says Jev was off"
  assert_absent "$TMP_ROOT/triage-off/calls" "a flag-off triage makes no Jev call"
  assert_absent "$home/state/wiki/jev.jsonl" "a flag-off triage records no Jev answer"
  assert_equals 'off' "$(plan_query "$plan" 'plan["jev"]["flag"]')" "the plan records that Jev was off"
  assert_equals '2' "$(plan_query "$plan" 'len(plan["lessons"])')" "the unannotated plan still lists every pending lesson"
  assert_equals 'None' "$(plan_query "$plan" 'plan["lessons"][0]["jev"]')" "an unannotated lesson carries no Jev answer"
  assert_equals 'pages/tools/firstmate.md' \
    "$(plan_query "$plan" 'plan["lessons"][0]["candidates"][0]')" \
    "the plan still lists the best grep candidate for the gardener"
  assert_equals 'raw/2026/10/20261025T010000Z-testhost-testhome-alpha-b1c2.md' \
    "$(plan_query "$plan" 'plan["lessons"][0]["path"]')" "the plan names the pending raw path"
  assert_not_contains "$(cat "$plan")" 'seed-a1b2' "a compiled lesson is not pending"
  assert_present "$home/data/gardener/report.md" "triage writes the gardener report beside the plan"
  assert_contains "$(cat "$home/data/gardener/report.md")" \
    '| Lesson | Jev route | Gardener page | Route agrees | Jev duplicate p | Jev keep p | Gardener kept |' \
    "the report carries the calibration table header"
  pass "triage writes a complete unannotated plan with Jev off"
}

test_triage_annotates_route_duplicate_and_keep_hints() {
  local home repo plan fake out
  repo=$(triage_fixture on extra)
  home=$(triage_home triage-on)
  plan="$home/data/gardener/plan.json"
  fake=$(fm_fakebin "$TMP_ROOT/triage-on")
  fm_fake_jev "$fake"
  out=$(FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_LOG="$TMP_ROOT/triage-on/calls" \
    FM_FAKE_JEV_P=0.44 run_wiki "$home" triage --repo "$repo" 2>&1) \
    || fail "a flag-on triage must exit 0: $out"
  assert_contains "$out" '6 call(s), 0 unavailable' "two lessons ask three advisory questions each"
  assert_equals '6' "$(wc -l < "$TMP_ROOT/triage-on/calls" | tr -d ' ')" \
    "every question reached the shim once"
  assert_equals 'pages/tools/firstmate.md' \
    "$(plan_query "$plan" 'plan["lessons"][0]["jev"]["route"]["choice"]')" \
    "the plan carries the routes-to-page answer"
  assert_equals '0.44' \
    "$(plan_query "$plan" 'plan["lessons"][0]["jev"]["duplicate"]["probability"]')" \
    "the plan carries the duplicate answer"
  assert_equals '0.44' \
    "$(plan_query "$plan" 'plan["lessons"][0]["jev"]["worth_keeping"]["probability"]')" \
    "the plan carries the worth-keeping answer"
  assert_equals 'on' "$(plan_query "$plan" 'plan["jev"]["flag"]')" "the plan records that Jev answered"
  assert_equals 'route duplicate worth_keeping route duplicate worth_keeping' \
    "$(python3 -c 'import json, sys; print(" ".join(json.loads(line)["verb"] for line in open(sys.argv[1]) if line.strip()))' "$home/state/wiki/jev.jsonl")" \
    "each answer is recorded beside the gardener's decision"
  assert_contains "$(head -n 1 "$home/state/wiki/jev.jsonl")" '"ok":true' "a recorded answer carries its verdict"
  assert_contains "$(cat "$home/data/gardener/report.md")" '| 0.44 | 0.44 |' \
    "the calibration table shows the recorded probabilities"
  assert_not_contains "$(cat "$home/state/wiki/jev.jsonl")" 'the firstmate test runner' \
    "the record holds identifiers and answers, never lesson text"
  pass "triage annotates route, duplicate, and worth-keeping answers behind the flag"
}

test_triage_calibration_table_labels_the_gardener_decision() {
  local home repo fake report bare base mode plan alpha beta gamma before row out
  local -a plan_args
  alpha=20261025T010000Z-testhost-testhome-alpha-b1c2
  beta=20261025T020000Z-testhost-testhome-beta-d3e4
  gamma=20261026T010000Z-testhost-testhome-gamma-e5f6
  for mode in default custom noop; do
    repo=$(triage_fixture "calib-$mode" extra)
    printf '\nDispatch routing craft.\n' >> "$repo/pages/tools/firstmate.md"
    home=$(triage_home "triage-calib-$mode")
    bare=$(wiki_bare "triage-calib-$mode")
    wiki_cfg "$home" gardener "file://$bare"
    wgit -C "$repo" init -q -b main
    wgit -C "$repo" remote add origin "file://$bare"
    wgit -C "$repo" add -A
    wgit -C "$repo" commit -q -m 'seed calibration batch'
    wgit -C "$repo" push -q origin main
    base=$(wgit -C "$repo" rev-parse HEAD)
    fake=$(fm_fakebin "$TMP_ROOT/triage-calib-$mode")
    fm_fake_jev "$fake"
    plan="$home/data/gardener/plan.json"
    plan_args=()
    if [ "$mode" = custom ]; then
      plan="$home/data/custom-batch/plan.json"
      plan_args=(--plan "$plan")
    fi
    FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_CHOICE=pages/tools/firstmate.md \
      run_wiki "$home" triage --repo "$repo" "${plan_args[@]}" >/dev/null 2>&1 \
      || fail "triage must precede compilation"
    before=$(cat "$plan")
    report=$(cat "$(dirname "$plan")/report.md")
    assert_contains "$report" '| pending |' "triage records pending outcomes before compilation"
    printf '\nKept claim ([lesson](../../raw/2026/10/%s.md)).\n' "$alpha" >> "$repo/pages/tools/firstmate.md"
    printf '\n## [2026-10-25] ingest | 2 lessons | %s; %s\n' "$alpha" "$beta" >> "$repo/log.md"
    if [ "$mode" = default ]; then
      printf '\ninvalid raw edit\n' >> "$repo/raw/2026/10/$alpha.md"
      out=$(run_wiki "$home" publish --repo "$repo" --base "$base" 2>&1)
      [ "$?" -ne 0 ] || fail "a raw edit must refuse publication"
      assert_equals "$report" "$(cat "$(dirname "$plan")/report.md")" "refused publication leaves outcomes pending"
      wgit -C "$repo" restore -- "raw/2026/10/$alpha.md"
    fi
    if [ "$mode" = noop ]; then
      run_wiki "$home" index --repo "$repo" >/dev/null || fail "prepare an already landed batch"
      wgit -C "$repo" add pages index.md log.md
      wgit -C "$repo" commit -q -m 'already landed compilation'
      wgit -C "$repo" push -q origin main
    fi
    out=$(FM_FAKE_JEV_LOG="$TMP_ROOT/triage-calib-$mode/publish-calls" \
      run_wiki "$home" publish --repo "$repo" --base "$base" "${plan_args[@]}" 2>&1) \
      || fail "compilation must publish before calibration: $out"
    [ "$mode" != noop ] || assert_contains "$out" 'nothing to publish' "the no-op success path also fills outcomes"
    assert_absent "$TMP_ROOT/triage-calib-$mode/publish-calls" "outcome recording makes no new model call"
    assert_equals "$before" "$(cat "$plan")" "completion changes report outcomes without replacing the plan or hints"
    report=$(cat "$(dirname "$plan")/report.md")
    assert_contains "$report" "| \`$alpha\` | \`pages/tools/firstmate.md\` | \`pages/tools/firstmate.md\` | yes | 0.4 | 0.4 | yes | \`pages/tools/firstmate.md\` | yes |" \
      "the published citation records route agreement, keeping, and duplicate merging"
    assert_contains "$report" "| \`$beta\` | \`pages/tools/firstmate.md\` | (none) | no | 0.4 | 0.4 | no | \`pages/tools/firstmate.md\` | no |" \
      "a logged lesson without a body citation records the gardener's drop"
    row=$(printf '%s\n' "$report" | grep -F "| \`$alpha\` |")
    cp "$repo/raw/2026/10/$alpha.md" "$repo/raw/2026/10/$gamma.md"
    wgit -C "$repo" add raw
    wgit -C "$repo" commit -q -m 'next raw lesson'
    wgit -C "$repo" push -q origin main
    base=$(wgit -C "$repo" rev-parse HEAD)
    FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_CHOICE='new page' \
      run_wiki "$home" triage --repo "$repo" "${plan_args[@]}" >/dev/null 2>&1 || fail "plan a later batch"
    assert_contains "$(cat "$(dirname "$plan")/report.md")" "$row" "later triage preserves the earlier calibration row"
    cp "$repo/pages/tools/firstmate.md" "$repo/pages/tools/new-page.md"
    printf '\nNew claim ([lesson](../../raw/2026/10/%s.md)).\n' "$gamma" >> "$repo/pages/tools/new-page.md"
    printf '\n## [2026-10-26] ingest | 1 lesson | %s\n' "$gamma" >> "$repo/log.md"
    run_wiki "$home" publish --repo "$repo" --base "$base" "${plan_args[@]}" >/dev/null 2>&1 || fail "publish the later batch"
    report=$(cat "$(dirname "$plan")/report.md")
    assert_contains "$report" "| \`$gamma\` | \`new page\` | \`pages/tools/new-page.md\` | yes |" \
      "new-page agreement compares with the pages that existed at triage"
    assert_contains "$report" "$row" "publishing a later batch retains the earlier outcome unchanged"
    run_wiki "$home" triage --repo "$repo" "${plan_args[@]}" >/dev/null 2>&1 || fail "flag-off triage still runs"
    report=$(cat "$(dirname "$plan")/report.md")
    assert_contains "$report" "$row" "flag-off triage retains past opt-in calibration"
    run_wiki "$home" publish --repo "$repo" --base "$base" "${plan_args[@]}" >/dev/null 2>&1 || fail "flag-off publication still runs"
    assert_equals "$report" "$(cat "$(dirname "$plan")/report.md")" "a flag-off batch causes no outcome write"
  done
  pass "published batches fill calibration outcomes and retain history for default and custom plans"
}

test_triage_publishes_every_lesson_when_jev_is_unavailable() {
  local home repo plan fake out offplan
  repo=$(triage_fixture unavailable extra)
  home=$(triage_home triage-unavailable)
  plan="$home/data/gardener/plan.json"
  offplan="$TMP_ROOT/triage-unavailable/off.json"
  fake=$(fm_fakebin "$TMP_ROOT/triage-unavailable")
  fm_fake_jev "$fake"
  run_wiki "$home" triage --repo "$repo" --plan "$offplan" >/dev/null 2>&1 \
    || fail "the flag-off baseline must run"
  out=$(FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_MODE=unavailable \
    run_wiki "$home" triage --repo "$repo" 2>&1) \
    || fail "an unavailable Jev must not fail triage: $out"
  assert_contains "$out" 'unavailable' "the triage line reports the unavailable answers"
  assert_equals '2' "$(plan_query "$plan" 'len(plan["lessons"])')" \
    "an unavailable Jev still plans every pending lesson"
  assert_equals 'None' "$(plan_query "$plan" 'plan["lessons"][0]["jev"]')" \
    "an unavailable answer never annotates a lesson"
  assert_equals "$(plan_query "$offplan" '[l["id"] for l in plan["lessons"]]')" \
    "$(plan_query "$plan" '[l["id"] for l in plan["lessons"]]')" \
    "the unavailable plan lists exactly the flag-off lessons in the same order"
  assert_equals '0' "$(plan_query "$plan" 'plan["jev"]["calls"] - plan["jev"]["unavailable"]')" \
    "every attempted call is recorded as unavailable"
  # An erroring shim is no different from an unavailable one.
  : > "$home/state/wiki/jev.jsonl"
  FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_MODE=error \
    run_wiki "$home" triage --repo "$repo" >/dev/null 2>&1 \
    || fail "an erroring Jev must not fail triage"
  assert_equals '2' "$(plan_query "$plan" 'len(plan["lessons"])')" "an erroring Jev still plans every lesson"
  assert_contains "$(cat "$home/state/wiki/jev.jsonl")" '"ok":false' "an erroring shim is recorded as unavailable"
  pass "an unavailable or erroring Jev changes nothing about the plan"
}

# contradiction_fixture <name>: a lint-clean checkout whose four pages share
# one scope, so the pair count and the cap are visible in the call log.
contradiction_fixture() {
  local dir="$TMP_ROOT/$1-repo" i
  mkdir -p "$dir/pages/tools" "$dir/raw/2026/10"
  printf '# Crew wiki index\n' > "$dir/index.md"
  printf '## [2026-10-24] ingest | 1 lesson | 20261024T000000Z-testhost-testhome-seed-a1b2\n' > "$dir/log.md"
  cat > "$dir/raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md" <<'EOF'
---
wiki: raw-lesson v1
wiki-home: testhome
wiki-task: seed
wiki-final: done
date: 2026-10-24
---

## seed lesson
scope: tool:seed
claim: the seed lesson exists
evidence: this fixture
EOF
  for i in 1 2 3 4; do
    cat > "$dir/pages/tools/page-$i.md" <<EOF
> summary: page $i of the shared scope
> scope: tool:shared
> last-confirmed: 2026-10-24
> sources: raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md

# Page $i

The seed lesson exists ([lesson](../../raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md)).
EOF
    printf -- '- [Page %s](pages/tools/page-%s.md) - page %s\n' "$i" "$i" "$i" >> "$dir/index.md"
  done
  printf '%s\n' "$dir"
}

test_lint_reports_capped_contradiction_candidates() {
  local home repo fake out i
  repo=$(contradiction_fixture cap)
  home=$(triage_home triage-contradictions)
  fake=$(fm_fakebin "$TMP_ROOT/triage-contradictions")
  fm_fake_jev "$fake"
  for i in $(seq 5 21); do
    cp "$repo/pages/tools/page-1.md" "$repo/pages/tools/page-$i.md"
  done
  out=$(FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_LOG="$TMP_ROOT/triage-contradictions/calls" \
    FM_WIKI_JEV_PAIRS_CAP=1000 FM_FAKE_JEV_P=0.62 \
    run_wiki "$home" lint --repo "$repo" 2>&1) || fail "contradiction candidates never block lint: $out"
  assert_equals '200' "$(wc -l < "$TMP_ROOT/triage-contradictions/calls" | tr -d ' ')" \
    "21 same-scope pages make 210 pairs but the fixed cap permits 200 calls"
  assert_contains "$out" 'jev contradiction candidates capped at 200 pairs this run' "the fixed cap is reported"
  assert_contains "$out" 'wiki lint advisory: jev contradiction candidate p=0.62:' "positive candidates stay advisory"
  assert_contains "$out" 'lint clean' "advisories never block publication"
  assert_equals '200' "$(grep -c '"verb":"contradicts"' "$home/state/wiki/jev.jsonl")" "each asked pair is recorded"
  repo=$(contradiction_fixture uncapped)
  : > "$TMP_ROOT/triage-contradictions/calls"
  out=$(FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_LOG="$TMP_ROOT/triage-contradictions/calls" \
    FM_WIKI_JEV_PAIRS_CAP=1 run_wiki "$home" lint --repo "$repo" 2>&1) || fail "small pair sets remain advisory"
  assert_equals '6' "$(wc -l < "$TMP_ROOT/triage-contradictions/calls" | tr -d ' ')" "obsolete tuning cannot lower the fixed cap"
  assert_not_contains "$out" 'capped at' "an uncapped run prints no cap line"
  pass "contradiction candidates use a fixed 200-pair cap"
}

test_lint_makes_no_contradiction_call_with_jev_off() {
  local home repo fake out baseline
  repo=$(contradiction_fixture quiet)
  home=$(triage_home triage-contradictions-off)
  fake=$(fm_fakebin "$TMP_ROOT/triage-contradictions-off")
  fm_fake_jev "$fake"
  baseline=$(run_wiki "$home" lint --repo "$repo" 2>&1) || fail "the flag-off baseline must run"
  out=$(FM_FAKE_JEV_LOG="$TMP_ROOT/triage-contradictions-off/calls" \
    run_wiki "$home" lint --repo "$repo" 2>&1) \
    || fail "a flag-off lint must stay exit 0"
  assert_absent "$TMP_ROOT/triage-contradictions-off/calls" "a flag-off lint makes no Jev call"
  assert_equals "$baseline" "$out" "a flag-off lint prints exactly its deterministic verdict"
  assert_not_contains "$out" 'jev' "a flag-off lint says nothing about Jev"
  pass "a flag-off lint is byte-identical and makes no Jev call"
}

test_triage_preserves_offered_routes() {
  local home repo fake plan report
  repo=$(triage_fixture route-choice)
  home=$(triage_home triage-route-choice)
  fake=$(fm_fakebin "$TMP_ROOT/triage-route-choice")
  fm_fake_jev "$fake"
  plan="$home/data/gardener/plan.json"
  FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_CHOICE='new page' \
    run_wiki "$home" triage --repo "$repo" >/dev/null 2>&1 || fail "new page must remain a valid route"
  assert_equals 'new page' "$(plan_query "$plan" 'plan["lessons"][0]["jev"]["route"]["choice"]')" \
    "the declared new-page option survives into the plan"
  report=$(cat "$home/data/gardener/report.md")
  assert_contains "$report" '| `new page` | (none yet) | - |' \
    "a new-page hint has no filename agreement to measure"
  mv "$repo/pages/tools/firstmate.md" "$repo/pages/tools/firstmate guide.md"
  FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_CHOICE='pages/tools/firstmate guide.md' \
    run_wiki "$home" triage --repo "$repo" >/dev/null 2>&1 || fail "an offered page with spaces must remain valid"
  assert_equals 'pages/tools/firstmate guide.md' \
    "$(plan_query "$plan" 'plan["lessons"][0]["jev"]["route"]["choice"]')" \
    "exact candidate membership accepts every offered filename"
  rm -f "$repo/pages/tools/firstmate guide.md" "$repo/pages/fleet/routing.md"
  FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_CHOICE='new page' \
    run_wiki "$home" triage --repo "$repo" >/dev/null 2>&1 || fail "new page must work without candidates"
  assert_equals 'new page' "$(plan_query "$plan" 'plan["lessons"][0]["jev"]["route"]["choice"]')" \
    "no matching page still produces the declared route hint"
  assert_equals 'None' "$(plan_query "$plan" 'plan["lessons"][0]["jev"].get("duplicate")')" \
    "no candidate means no duplicate target"
  pass "triage retains new-page and spaced-filename choices"
}

test_triage_calibration_uses_body_citations() {
  local home repo fake page raw report id
  repo=$(triage_fixture citation-labels)
  home=$(triage_home triage-citation-labels)
  fake=$(fm_fakebin "$TMP_ROOT/triage-citation-labels")
  fm_fake_jev "$fake"
  page="$repo/pages/tools/firstmate.md"
  id=20261025T010000Z-testhost-testhome-alpha-b1c2
  raw="raw/2026/10/$id.md"
  printf '> summary: firstmate tooling craft\n> scope: tool:firstmate\n> sources: %s\n\n' "$raw" > "$page"
  printf '\140\140\140md\n[example](../../%s)\n\140\140\140\n\n\140[inline example](../../%s)\140\n' "$raw" "$raw" >> "$page"
  FM_WIKI_JEV="$fake/fm-jev-fake" run_wiki "$home" triage --repo "$repo" >/dev/null 2>&1 \
    || fail "triage must label a lesson mentioned only in metadata and code"
  report=$(cat "$home/data/gardener/report.md")
  assert_contains "$report" '| (none yet) | pending |' "metadata and code do not prove a route was taken"
  assert_contains "$report" '| pending | 0.4 | 0.4 | pending |' "metadata and code do not prove the lesson was kept"
  printf '\n> A supported claim [from the lesson][source].\n\n[source]: ../../%s\n' "$raw" >> "$page"
  FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_CHOICE=pages/tools/firstmate.md \
    run_wiki "$home" triage --repo "$repo" --plan "$home/data/body-citations/plan.json" >/dev/null 2>&1 || fail "reference citations must count"
  report=$(cat "$home/data/body-citations/report.md")
  assert_contains "$report" '| `pages/tools/firstmate.md` | `pages/tools/firstmate.md` | yes |' \
    "quoted reference links resolve through the same citation parser as lint"
  assert_contains "$report" '| 0.4 | 0.4 | yes |' "a resolved body citation proves the lesson was kept"
  pass "calibration distinguishes metadata and code from resolved body citations"
}

test_jev_does_not_send_secret_inputs() {
  local home repo fake location out calls token
  token=ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD
  for location in lesson summary page; do
    repo=$(triage_fixture "secret-$location")
    home=$(triage_home "triage-secret-$location")
    fake=$(fm_fakebin "$TMP_ROOT/triage-secret-$location")
    fm_fake_jev "$fake"
    calls="$TMP_ROOT/triage-secret-$location/calls"
    case $location in
      lesson) printf '\n%s\n' "$token" >> "$repo/raw/2026/10/20261025T010000Z-testhost-testhome-alpha-b1c2.md" ;;
      summary) printf '> summary: firstmate %s\n' "$token" > "$repo/pages/tools/firstmate.md" ;;
      page) printf '\n%s\n' "$token" >> "$repo/pages/tools/firstmate.md" ;;
    esac
    out=$(FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_LOG="$calls" FM_FAKE_JEV_REQUEST_LOG="$calls.requests" \
      run_wiki "$home" triage --repo "$repo" 2>&1) || fail "unsafe advisory input must not block planning: $out"
    assert_equals '1' "$(plan_query "$home/data/gardener/plan.json" 'len(plan["lessons"])')" \
      "secret scanning advisories never drops a lesson from the plan"
    if [ "$location" = page ]; then
      assert_equals 'route worth_keeping' "$(cut -f1 "$calls" | paste -sd ' ' -)" \
        "an unsafe duplicate page is skipped while safe route and keep calls remain"
      assert_not_contains "$(cat "$calls.requests")" "$token" "no outgoing triage request contains the credential"
    else
      assert_absent "$calls" "unsafe lesson or summary content never reaches the shim"
    fi
  done
  repo=$(contradiction_fixture secret-pairs)
  home=$(triage_home triage-secret-pairs)
  fake=$(fm_fakebin "$TMP_ROOT/triage-secret-pairs")
  fm_fake_jev "$fake"
  printf '\n%s\n' "$token" >> "$repo/pages/tools/page-1.md"
  calls="$TMP_ROOT/triage-secret-pairs/calls"
  out=$(FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_LOG="$calls" FM_FAKE_JEV_REQUEST_LOG="$calls.requests" \
    run_wiki "$home" lint --repo "$repo" 2>&1) || fail "unsafe advisories must not change deterministic lint: $out"
  assert_equals '3' "$(wc -l < "$calls" | tr -d ' ')" "three safe pairs still run after three unsafe pairs"
  assert_contains "$out" 'lint clean' "secret suppression does not alter the lint verdict"
  printf '\n[broken](missing.md)\n' >> "$repo/pages/tools/page-2.md"
  : > "$calls"
  out=$(FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_LOG="$calls" FM_FAKE_JEV_REQUEST_LOG="$calls.requests" \
    run_wiki "$home" lint --repo "$repo" 2>&1)
  [ "$?" -ne 0 ] || fail "deterministic link errors must still block lint"
  assert_equals '3' "$(wc -l < "$calls" | tr -d ' ')" "blocked lint also skips every unsafe pair"
  assert_not_contains "$(cat "$calls.requests")" "$token" "no outgoing contradiction request contains the credential"
  pass "all gardener advisories scan inputs without changing deterministic decisions"
}

test_publish_keeps_jev_outside_its_budget_and_lock() {
  local home bare repo fake base out lock
  bare=$(wiki_bare publish-jev-budget)
  seed_checkout "$bare" "$TMP_ROOT/publish-jev-budget-seed" >/dev/null
  home=$(gardener_home_with_repo publish-jev-budget "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  cp "$repo/pages/tools/seed-page.md" "$repo/pages/tools/other.md"
  fake=$(fm_fakebin "$TMP_ROOT/publish-jev-budget")
  fm_fake_jev "$fake"
  lock="$home/state/wiki/.drain.lock"
  out=$(FM_WIKI_JEV="$fake/fm-jev-fake" FM_FAKE_JEV_LOG="$TMP_ROOT/publish-jev-budget/calls" \
    FM_FAKE_JEV_DELAY=9 FM_FAKE_JEV_MODE=unavailable FM_FAKE_JEV_LOCK="$lock" \
    FM_WIKI_JEV_TIMEOUT=1 FM_WIKI_PUBLISH_CAP=5 \
    run_wiki "$home" publish --base "$base" 2>&1) || fail "slow unavailable Jev must not prevent publication: $out"
  assert_equals '1' "$(wc -l < "$TMP_ROOT/publish-jev-budget/calls" | tr -d ' ')" \
    "one eight-second timeout exceeds the five-second Git budget"
  assert_equals 'True' "$(python3 -c 'import json, sys; print(json.loads(open(sys.argv[1]).read())["latency_ms"] >= 7500)' "$home/state/wiki/jev.jsonl")" \
    "obsolete timeout tuning cannot shorten the fixed eight-second bound"
  assert_equals 'free' "$(paste -sd ' ' "$lock.observed")" \
    "every external advisory runs without the exclusive publication lock"
  assert_contains "$out" 'wiki: published' "healthy remote still receives the compiled pages"
  assert_equals "$(wgit -C "$repo" rev-parse HEAD)" "$(wgit -C "$bare" rev-parse main)" \
    "publication proves the remote landing after unavailable advisories"
  pass "slow Jev calls consume neither publication budget nor exclusive lock"
}

test_triage_uses_fixed_bounds() {
  local home repo plan i out
  repo=$(triage_fixture fixed-bounds)
  home=$(triage_home triage-fixed-bounds)
  for i in $(seq 1 30); do
    cp "$repo/raw/2026/10/20261025T010000Z-testhost-testhome-alpha-b1c2.md" "$repo/raw/2026/10/20261026T010000Z-testhost-testhome-extra-$i.md"
  done
  for i in $(seq 1 10); do
    cp "$repo/pages/tools/firstmate.md" "$repo/pages/tools/extra-$i.md"
  done
  FM_WIKI_JEV_CANDIDATES=1000 run_wiki "$home" triage --repo "$repo" >/dev/null 2>&1 || fail "fixed-bound triage must run"
  plan="$home/data/gardener/plan.json"
  assert_equals '25' "$(plan_query "$plan" 'len(plan["lessons"])')" "the gardener contract limits every batch to 25 lessons"
  assert_equals '8' "$(plan_query "$plan" 'max(len(lesson["candidates"]) for lesson in plan["lessons"])')" "every route menu has at most eight existing pages"
  out=$(run_wiki "$home" triage --repo "$repo" --limit 100 2>&1)
  assert_equals '2' "$?" "removed batch-limit tuning is rejected"
  assert_contains "$out" "unknown triage flag '--limit'" "unsupported tuning has no alternate path"
  pass "triage fixes batches at 25 lessons and candidates at eight"
}

test_absent_config_keeps_gardener_verbs_silent
test_non_gardener_roles_cannot_run_the_gardener_verbs
test_due_fires_at_25_uncompiled_lessons
test_due_fires_on_a_seven_day_old_lesson
test_due_counts_only_lessons_the_log_has_not_cited
test_due_counts_a_lesson_the_log_names_by_bare_id
test_due_keeps_a_prefix_of_a_logged_id_pending
test_due_reads_ids_separated_by_semicolons_and_commas
test_due_stays_quiet_while_a_gardener_task_is_open
test_lint_passes_a_well_formed_checkout
test_lint_blocks_on_header_link_budget_and_citation_gaps
test_lint_blocks_over_budget_pages_and_indexes
test_lint_reports_advisories_without_blocking
test_index_regenerates_from_page_headers
test_publish_lands_pages_with_a_landing_proof
test_publish_refuses_a_raw_edit
test_publish_refuses_a_foreign_page_commit

test_due_includes_queued_backlog_tasks
test_lint_requires_existing_raw_lesson_citations
test_uncited_advisory_ignores_ingest_logs_and_indexes
test_generated_gardener_commands_target_a_linked_worktree
test_publish_checks_foreign_commits_on_push_retries
test_publish_retries_its_own_unproved_landing

test_due_reads_adapter_backlogs_without_markdown
test_lint_checks_every_citation_and_parses_markdown_titles
test_publish_refuses_raw_changes_even_when_restored
test_publish_refreshes_scheduling_from_a_separate_clone

test_lint_resolves_reference_links_and_excludes_code_examples
test_gardener_verbs_reject_equals_form_options

test_idle_gardener_drains_discover_upstream_lessons
test_idle_gardener_refresh_preserves_divergent_local_history
test_gardener_commands_bind_custom_home_paths

test_idle_gardener_refresh_is_bounded_and_recovers

test_lint_and_publish_require_pinned_lychee
test_lint_includes_quoted_claims_and_checks_links_offline
test_publish_and_drain_refuse_other_effective_push_urls
test_triage_writes_an_unannotated_plan_with_jev_off
test_triage_annotates_route_duplicate_and_keep_hints
test_triage_calibration_table_labels_the_gardener_decision
test_triage_publishes_every_lesson_when_jev_is_unavailable
test_lint_reports_capped_contradiction_candidates
test_lint_makes_no_contradiction_call_with_jev_off
test_triage_preserves_offered_routes
test_triage_calibration_uses_body_citations
test_jev_does_not_send_secret_inputs
test_publish_keeps_jev_outside_its_budget_and_lock
test_triage_uses_fixed_bounds
