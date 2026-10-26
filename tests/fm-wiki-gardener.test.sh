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

test_absent_config_keeps_gardener_verbs_silent
test_non_gardener_roles_cannot_run_the_gardener_verbs
test_due_fires_at_25_uncompiled_lessons
test_due_fires_on_a_seven_day_old_lesson
test_due_counts_only_lessons_the_log_has_not_cited
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
