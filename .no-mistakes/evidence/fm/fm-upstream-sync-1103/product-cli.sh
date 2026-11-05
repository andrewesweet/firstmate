#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB="$ROOT/.test-phase-tmp/product-cli"
EVIDENCE=~/.no-mistakes/evidence/01M6PPNG6H1R7WRHVY6CWGFJXH
bin/fm-lab-home.sh create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_SUPERVISION_ACTOR FM_BACKEND
export FM_HOME="$LAB"
touch "$LAB/config/supervision-host-off"
cat > "$LAB/data/projects.md" <<'EOF'
## Projects
- standard [no-mistakes]
- hand-written [no-mistakes pr=manual branch=feature/]
- forked [no-mistakes]
- wiki [direct-push]
- invalid [direct-push pr=manual]
EOF
printf 'Standard project: '; bin/fm-project-mode.sh standard
printf 'Manual project: '; bin/fm-project-mode.sh hand-written
printf 'Manual text: '; bin/fm-project-mode.sh --pr hand-written
printf 'Manual branch: '; bin/fm-project-mode.sh --branch-prefix hand-written
printf 'Wiki direct push: '; bin/fm-project-mode.sh wiki
if bin/fm-project-mode.sh invalid; then echo 'ERROR: accepted invalid posture'; exit 1; else printf 'Invalid manual/direct-push combination refused: exit=%s\n' "$?"; fi
bin/fm-brief.sh manual-proof hand-written --mode no-mistakes --pr manual --branch-prefix feature/
cp "$LAB/data/manual-proof/brief.md" "$EVIDENCE/manual-brief.md"
bin/fm-brief.sh fork-proof forked --mode no-mistakes --fork-staged acme/widgets
cp "$LAB/data/fork-proof/brief.md" "$EVIDENCE/fork-brief.md"
bin/fm-brief.sh wiki-proof wiki --mode direct-push
cp "$LAB/data/wiki-proof/brief.md" "$EVIDENCE/wiki-brief.md"
printf '\nQueue final notification with no task records:\n'
. "$ROOT/bin/fm-wake-lib.sh"
fm_wake_append check lab-final-result 'Final result remains deliverable after last worker cleanup.'
cat "$LAB/state/.wake-queue"
printf '\nDrain queued result:\n'
"$ROOT/bin/fm-wake-drain.sh" > "$LAB/drain.out"
cat "$LAB/drain.out"
grep -F 'Final result remains deliverable after last worker cleanup.' "$LAB/drain.out" >/dev/null
[ -s "$LAB/state/.wake-queue" ] || { echo 'ERROR: drain consumed result before acknowledgement'; exit 1; }
printf '\nResult remains durable until acknowledgement.\n'
