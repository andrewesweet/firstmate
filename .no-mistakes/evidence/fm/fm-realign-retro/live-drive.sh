#!/usr/bin/env bash
# Live drive of bin/fm-retro-trigger.sh and the fm-wake-lib.sh presentation hook in disposable homes.
set -u
W=$1; RT=$W/bin/fm-retro-trigger.sh; TMP=$(mktemp -d)
mkhome(){ h=$TMP/$1; mkdir -p $h/config $h/state/retro-trigger/receipts/g1 $h/data; printf 'spend_usd=10000\ndone_unseen_minutes=30\n' >$h/config/retro-cadence; echo g1>$h/state/retro-trigger/generation; echo retro-trigger-g1>$h/state/retro-trigger/open-row; echo $h; }
mkbin(){ d=$TMP/$1-bin; mkdir -p $d; for t in env bash sh awk basename cat cut date dirname head ln mktemp mkdir mv printf ps readlink rm rmdir sed sleep sort uname wc grep; do s=$(command -v $t) && ln -sf $s $d/$t; done; [ $2 = 1 ] && ln -sf $(command -v shasum) $d/shasum; [ $3 = 1 ] && ln -sf $(command -v sha256sum) $d/sha256sum; echo $d; }
run(){ b=$1 h=$2; shift 2; PATH=$b FM_CONFIG_OVERRIDE=$h/config FM_STATE_OVERRIDE=$h/state FM_DATA_OVERRIDE=$h/data "$RT" "$@"; }
for combo in "shasum-only 1 0" "sha256sum-only 0 1" "both-absent 0 0"; do set -- $combo
  echo "=== $1: PATH has shasum=$2 sha256sum=$3"; b=$(mkbin $1 $2 $3); h=$(mkhome $1)
  run $b $h observe anomaly needs-decision t1 "key-one"; echo "rc=$?"
  run $b $h observe anomaly needs-decision t1 "key-two"; echo "rc=$?"
  run $b $h observe anomaly needs-decision t1 "key-one"; echo "rc=$? (replay)"
  echo "receipts:"; ls $h/state/retro-trigger/receipts/g1/ | sed 's/^/  /'
done
echo "=== expected suffixes (independent sha256sum):"
for k in key-one key-two; do printf '  %s -> %s\n' $k $(printf '%s\n' needs-decision t1 $k | sha256sum | cut -c1-8); done
echo "=== broken selected hasher (shasum on PATH exits 1)"
b=$(mkbin broken 0 0); printf '#!/bin/sh\necho boom >&2; exit 1\n' >$b/shasum; chmod +x $b/shasum; h=$(mkhome broken)
run $b $h observe anomaly blocked t1 "x"; echo "rc=$?"; echo "receipts: $(ls $h/state/retro-trigger/receipts/g1 | wc -l)"
echo "=== malformed hasher output (shasum prints a short non-hex digest)"
b=$(mkbin malformed 0 0); printf '#!/bin/sh\necho "ZZZ  -"\n' >$b/shasum; chmod +x $b/shasum; h=$(mkhome malformed)
run $b $h observe anomaly blocked t1 "x"; echo "rc=$?"; echo "receipts: $(ls $h/state/retro-trigger/receipts/g1 | wc -l)"
echo
echo "##### presentation hook: wake drain of a status line"
old=$(( $(date +%s) - 3600 ))
for line in "done: PR https://e/1" "done [at=$old]: PR https://e/2" "done corr=0123456789abcdef [at=$old]: PR https://e/3" \
            "needs-decision [at=$old] [key=cap-10]: pick" "blocked [at=$old]: stuck" "working [at=$old]: busy" "donezo: not a verb"; do
  h=$(mkhome hook$RANDOM); printf '%s\n' "$line" >$h/state/crew.status
  printf '%s\t1\tsignal\tcrew.status\tsignal: x\n' $old >$h/state/.wake-queue
  out=$(FM_STATE_OVERRIDE=$h/state FM_CONFIG_OVERRIDE=$h/config FM_DATA_OVERRIDE=$h/data bash -c '. "$1"; . "$2"; fm_wake_print_annotations "$(fm_wake_print_deduped "$3")"' _ $W/bin/fm-classify-lib.sh $W/bin/fm-wake-lib.sh $h/state/.wake-queue 2>&1)
  echo "--- status line: $line"; echo "$out" | sed 's/^/  drain> /'
  for r in $h/state/retro-trigger/receipts/g1/*.receipt; do [ -e "$r" ] || { echo "  receipt: (none)"; continue; }; echo "  receipt $(basename $r): $(grep -E '^(kind|evidence)=' $r | tr '\n' ' ')"; done
done
rm -rf $TMP
