#!/usr/bin/env bash
set -eu
ROOT=$PWD
export FM_ROOT_OVERRIDE=$ROOT
export PATH=~/.no-mistakes/evidence/01M5TCVMDB06VFT51ANYBBV6BK/lychee-tools/lychee-x86_64-unknown-linux-gnu:$PATH
export TMPDIR=$ROOT/.test-gardener/tmp
EVIDENCE=~/.no-mistakes/evidence/01M5TCVMDB06VFT51ANYBBV6BK
source <(sed '/^test_absent_config_keeps_gardener_verbs_silent$/,$d' tests/fm-wiki-gardener.test.sh)
set -e
bare=$(wiki_bare age)
seed_checkout "$bare" "$TMP_ROOT/seed" >/dev/null
home=$(gardener_home_with_repo age "$bare")
repo=$home/state/wiki/repo
stamp=$(date -u -d '6 days 23 hours ago' +%Y%m%dT%H%M%SZ)
lesson=$(add_raw "$repo" "$stamp" boundary)
wgit -C "$repo" add -A
wgit -C "$repo" commit -qm 'Lesson younger than seven days'
printf '$ fm-wiki.sh due # 6 days 23 hours old\n'
rc=0; out=$(run_wiki "$home" due 2>&1) || rc=$?
printf '%s\nexit=%s\n' "$out" "$rc"
[ "$rc" -ne 0 ] && [ -z "$out" ] || fail 'under seven days must stay quiet'
oldstamp=$(date -u -d '7 days ago' +%Y%m%dT%H%M%SZ)
mv "$lesson" "$(dirname "$lesson")/${oldstamp}-testhost-testhome-boundary-a1b2.md"
wgit -C "$repo" add -A
wgit -C "$repo" commit -qm 'Lesson exactly seven days old'
printf '$ fm-wiki.sh due # seven days old\n'
run_wiki "$home" due || fail 'seven-day boundary must schedule'
printf '\nexit=0\n'

# One category uses six heading lines; the 144th entry reaches 150 lines.
for i in $(seq 2 144); do cp "$repo/pages/tools/seed-page.md" "$repo/pages/tools/page-$i.md"; done
printf '\n$ fm-wiki.sh index # 144 pages\n'
run_wiki "$home" index || fail '150-line index must be accepted'
[ "$(wc -l < "$repo/index.md")" -eq 150 ] || fail 'exactly 150 lines expected'
printf 'exit=0; generated line count=150\n'
cp "$repo/pages/tools/seed-page.md" "$repo/pages/tools/page-145.md"
printf '\n$ fm-wiki.sh index # 145 pages\n'
rc=0; run_wiki "$home" index || rc=$?
[ "$rc" -ne 0 ] || fail '151-line index must be rejected'
[ "$(wc -l < "$repo/index.md")" -eq 151 ] || fail 'generated output expected'
printf 'exit=%s; generated line count=151\n' "$rc"

# The registry guard is exercised without backend stubs. The marked home and
# private socket path prevent any accidental access to operator fleet state.
lab=$TMP_ROOT/spawn-lab
"$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null
mkdir -p "$lab/tmux"
project=$lab/projects/crew-wiki
git clone -q "file://$bare" "$project"
printf '%s\n' '- crew-wiki [direct-PR] - no direct-push consent' > "$lab/data/projects.md"
FM_HOME="$lab" "$ROOT/bin/fm-brief.sh" boundary-g1 crew-wiki --mode direct-push >/dev/null
python3 - "$lab/data/boundary-g1/brief.md" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Compile wiki pages.').replace('{PUBLISHED_INTENT}', 'Compile wiki pages.').replace('{FIRSTMATE_SPEC}', 'Compile pending lessons and publish.'))
PY
printf '\n$ fm-spawn.sh boundary-g1 <isolated-project> claude --mode direct-push --yolo off\n'
rc=0
out=$(env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$lab" TMUX_TMPDIR="$lab/tmux" FM_BACKEND=tmux \
  "$ROOT/bin/fm-spawn.sh" boundary-g1 "$project" claude --mode direct-push --yolo off 2>&1) || rc=$?
printf '%s\nexit=%s\n' "$out" "$rc"
[ "$rc" -ne 0 ] || fail 'unopted project must be refused'
assert_contains "$out" 'permitted only for a project whose registry entry opts in' 'real spawn registry refusal'
[ ! -e "$lab/state/boundary-g1.meta" ] || fail 'refusal must not record a task'
printf 'No task metadata created.\n'
