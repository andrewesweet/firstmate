#!/usr/bin/env bash
set -u
cd "$WT"
eval "$(sed -n "1,137p" tests/fm-fleet-snapshot-view.test.sh | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$WT/tests#" | sed '/^command -v jq/d')"
home=$(make_home parity); write_fixture "$home"
# adversarial content-bearing text: quotes, backslashes, unicode, tabs, $, ~20KiB (under argv cap so base can run)
mid=$(head -c 20000 /dev/zero | tr '\0' 'x')
printf 'needs-decision: pick "A" or \\B\\ — ünïcødé\t$HOME `x` %s\n' "$mid" > "$home/state/ship-task.status"
printf 'working [key=k1]: watching "scope" \\ and ✓ tabs\there\n' >> "$home/state/secondmate-task.status"
fb=$(make_fakebin "$home")
for side in base head; do
  if [ $side = base ]; then S=$BASE/bin/fm-fleet-snapshot.sh; V=$BASE/bin/fm-fleet-view.sh; else S=$WT/bin/fm-fleet-snapshot.sh; V=$WT/bin/fm-fleet-view.sh; fi
  for mode in --json --contribution-input; do
    PATH="$fb:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW_EPOCH=1700000100 FM_SNAPSHOT_NOW=2023-11-14T22:15:00Z "$S" $mode > "$OUT/$side${mode}.out" 2>"$OUT/$side${mode}.err"; echo "$side $mode rc=$?"
  done
  PATH="$fb:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW_EPOCH=1700000100 FM_SNAPSHOT_NOW=2023-11-14T22:15:00Z "$S" > "$OUT/$side-default.out" 2>&1; echo "$side default rc=$?"
done
