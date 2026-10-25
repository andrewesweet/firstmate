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

A body citing raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md.
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

Body citing raw/2026/10/20261025T000000Z-testhost-testhome-task-a-a1b2.md.
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

Body citing raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md.
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

Body citing raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md.
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
  local home bare repo out base landed
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

Body citing raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md.
EOF
  printf '## [2026-10-25] ingest | 1 lesson | 20261024T000000Z-testhost-testhome-seed-a1b2.md\n' >> "$repo/log.md"
  out=$(run_wiki "$home" publish --base "$base" 2>&1) || fail "publish must exit 0: $out"
  assert_contains "$out" 'published' "publish reports the landing"
  landed=$(wgit -C "$bare" rev-parse main)
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

Body citing raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md.
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

Body citing raw/2026/10/20261024T000000Z-testhost-testhome-seed-a1b2.md.
EOF
  remote_before=$foreign
  out=$(run_wiki "$home" publish --base "$base" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "publish must refuse after a foreign page commit"
  assert_contains "$out" 'foreign' "the refusal names the foreign page commit"
  assert_equals "$remote_before" "$(wgit -C "$bare" rev-parse main)" "a refused publish pushes nothing"
  pass "publish refuses a foreign page commit"
}

test_due_includes_queued_backlog_tasks() {
  local home bare repo out status section
  bare=$(wiki_bare duequeued)
  seed_checkout "$bare" "$TMP_ROOT/duequeued-seed" >/dev/null
  home=$(gardener_home_with_repo duequeued "$bare")
  repo="$home/state/wiki/repo"
  add_raw "$repo" 20200101T000000Z task-old >/dev/null
  wgit -C "$repo" add -A
  wgit -C "$repo" commit -q -m "wiki: pending lesson"
  for section in Queued 'In flight'; do
    printf '## %s\n- [ ] garden-q1 - compile pending lessons (repo: crew-wiki)\n\n## Done\n' "$section" > "$home/data/backlog.md"
    out=$(run_wiki "$home" due 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "due must suppress an open backlog task in $section"
    assert_equals '' "$out" "open backlog task suppresses due silently"
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
  out=$(run_wiki "$home" lint 2>&1) || fail "uncited advisory must not block lint: $out"
  assert_contains "$out" "raw lesson no page cites after 30 days: ${lesson#"$repo/"}" "ingest records do not count as page citations"
  printf '\nSource: %s\n' "${lesson#"$repo/"}" >> "$repo/pages/tools/seed-page.md"
  out=$(run_wiki "$home" lint 2>&1) || fail "citing the lesson must keep lint clean: $out"
  assert_not_contains "$out" 'raw lesson no page cites after 30 days:' "a page citation clears the advisory"
  pass "uncited lesson advisories consider pages only"
}

test_generated_gardener_commands_target_a_linked_worktree() {
  local home bare repo task_copy base brief commands out unchanged
  bare=$(wiki_bare linkedpublish)
  seed_checkout "$bare" "$TMP_ROOT/linkedpublish-seed" >/dev/null
  home=$(gardener_home_with_repo linkedpublish "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  task_copy="$TMP_ROOT/linked task"
  wgit -C "$repo" worktree add -q -b garden-linked "$task_copy" HEAD || fail "linked task copy failed"
  printf '\nA compiled addition.\n' >> "$task_copy/pages/tools/seed-page.md"
  unchanged=$(wgit -C "$repo" status --porcelain)
  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" garden-x1 crew-wiki --mode direct-push >/dev/null || fail "gardener brief failed"
  brief="$home/data/garden-x1/brief.md"
  assert_not_contains "$(cat "$brief")" 'no-mistakes doctor' "generated direct-push setup must not prescribe pipeline initialization"
  assert_not_contains "$(cat "$brief")" 'no-mistakes init' "generated direct-push setup must not initialize a pipeline"
  commands=$(python3 - "$brief" <<'PYTHON'
import re
import sys
for line in open(sys.argv[1]):
    if line.startswith(("Run `", "Then run `")):
        for command in re.findall(r"`([^`]+)`", line):
            if "fm-wiki.sh " in command:
                print(command)
PYTHON
)
  [ "$(printf '%s\n' "$commands" | wc -l | tr -d ' ')" = 3 ] || fail "generated contract must deliver lint, index, publish commands"
  out=$(cd "$task_copy" && FM_HOME="$home" BASE="$base" bash -e -c "$commands" 2>&1) || fail "generated commands failed from the wiki task copy: $out"
  assert_contains "$out" published "generated publish command lands the task copy"
  wgit -C "$bare" show main:pages/tools/seed-page.md | grep -q 'A compiled addition' || fail "task page change did not land"
  assert_equals "$base" "$(wgit -C "$repo" rev-parse HEAD)" "shared clone stays at its original head"
  assert_equals "$unchanged" "$(wgit -C "$repo" status --porcelain)" "generated commands leave shared files untouched"
  pass "generated commands lint, index, and publish a linked task copy"
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
  local home bare repo base out status fakebin real_git marker landed
  bare=$(wiki_bare publishunproved)
  seed_checkout "$bare" "$TMP_ROOT/publishunproved-seed" >/dev/null
  home=$(gardener_home_with_repo publishunproved "$bare")
  repo="$home/state/wiki/repo"
  base=$(wgit -C "$repo" rev-parse HEAD)
  printf '\nA compiled addition.\n' >> "$repo/pages/tools/seed-page.md"
  fakebin="$TMP_ROOT/proof-bin"
  marker="$TMP_ROOT/proof-fetch-failed"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${3:-}" = fetch ] && [ "${6:-}" = main ] && [ ! -f %q ]; then\n' "$marker"
    printf '  touch %q; exit 1\nfi\n' "$marker"
    printf 'exec %q "$@"\n' "$real_git"
  } > "$fakebin/git"
  chmod +x "$fakebin/git"
  out=$(PATH="$fakebin:$PATH" run_wiki "$home" publish --base "$base" 2>&1); status=$?
  [ -f "$marker" ] || fail "landing-proof fetch failure was not injected"
  [ "$status" -ne 0 ] || fail "failed proof fetch must leave landing unproved"
  assert_contains "$out" unproved "publish reports the missing landing proof"
  landed=$(wgit -C "$bare" rev-parse main)
  assert_not_equals "$base" "$landed" "the first push landed before proof fetch failed"
  out=$(run_wiki "$home" publish --base "$base" 2>&1) || fail "retry must accept this run's own landed commit: $out"
  assert_not_contains "$out" 'foreign page commit' "own commit is not foreign"
  assert_equals "$landed" "$(wgit -C "$bare" rev-parse main)" "retry does not create a duplicate commit"
  pass "publish retries its own unproved landing"
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
