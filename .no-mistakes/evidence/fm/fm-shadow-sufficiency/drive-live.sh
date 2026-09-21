#!/usr/bin/env bash
# Live driver: builds an isolated firstmate home, seeds a shadow log, runs the
# real scorer in both modes, arms the documented when-watch with the real
# fm-procevent-when.sh, lets the real runner poll it, and shows the check wake
# the notify action appends. Nothing here stubs the product.
set -u
umask 022
ROOT=/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M30TRJ424WQMRVFZ0T973XRJ
EV=/home/andre/.no-mistakes/evidence/01M30TRJ424WQMRVFZ0T973XRJ
H=$(mktemp -d /tmp/nm-shadow-live/home.XXXXXX)
S="$H/state"; mkdir -p "$S"
GATES="$ROOT/bin/fm-branch-shadow-gates.sh"
OUTC="$ROOT/bin/fm-branch-outcome.sh"
export FM_HOME="$H"
pe()   { "$ROOT/bin/fm-procevent.sh" "$@"; }
when() { "$ROOT/bin/fm-procevent-when.sh" "$@"; }
say()  { printf '\n$ %s\n' "$*"; }

sev='["False alarm or no functional impact","Routine recoverable interruption or non-blocking failure","Task blocked or failed after normal recovery","Security, privacy, data-loss, irreversible, credential, or external-publication impact"]'
mk_rec() {  # <task> <wakeKey> <noul> <t-offset>
  local task=$1 wk=$2 noul=$3 off=$4 t
  t=$(date -u -d "@$((1700000000 + off))" +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' '{"t":"'"$t"'","kind":"shadow","wake":"signal: A","seqs":["1"],"wakeKey":"'"$wk"'","tasks":["'"$task"'"],"wakeNo":1,"variant":"full","repeat":1,"control":false,"unavailable":null,"requestBytes":10,"ms":5,"policy":{"choice_confidence_floor":0.85,"noul_grant_below":0.15,"noul_pass_above":0.85},"answers":{"no_new_outcome":{"type":"noul","noul":'"$noul"'}},"facts":{"wake_key":"'"$wk"'","new_status_bytes":{"'"$task"'":0},"pane":"fm-'"$task"'","authoritative_pr":{"present":false},"severity_classes":'"$sev"'}}' >> "$S/branch-mod-shadow.jsonl"
  "$OUTC" append --task "$task" --verdict routine --summary 'signal noted' --wake-key "$wk" >/dev/null
}

echo "== home: $H"
printf 'id=t1\nwindow=fm-t1\nbackend=tmux\n' > "$S/t1.meta"
printf 'working: t1\n' > "$S/t1.status"
for n in $(seq 1 60); do mk_rec t1 "1701:$n" 0.9 "$n"; done
for n in $(seq 61 90); do
  mk_rec t1 "1701:$n" 0.5 "$n"
  "$OUTC" append --task t1 --verdict captain --summary 'escalated' --wake-key "1701:$n" >/dev/null
done

say "$GATES   # ordinary report (new sufficiency table at the end)"
"$GATES"; echo "exit=$?"

say "$GATES --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 30   # expect exit 0"
"$GATES" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 30 | tail -4; echo "exit=${PIPESTATUS[0]}"

say "$GATES --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 31   # expect exit 1 (not yet)"
"$GATES" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 31 | tail -3; echo "exit=${PIPESTATUS[0]}"

say "$GATES --sufficient absorb-no-new-outcome,candidate-order --bound 0.05 --min-positives 0   # a second named gate with no evidence: exit 1"
"$GATES" --sufficient absorb-no-new-outcome,candidate-order --bound 0.05 --min-positives 0 | tail -4; echo "exit=${PIPESTATUS[0]}"

say "$GATES --sufficient bogus --bound 0.05   # usage error: exit 2"
"$GATES" --sufficient bogus --bound 0.05; echo "exit=$?"
say "$GATES --sufficient absorb-no-new-outcome --bound 2   # bound out of range: exit 2"
"$GATES" --sufficient absorb-no-new-outcome --bound 2; echo "exit=$?"
mkdir "$S/unreadable.jsonl"
say "$GATES --sufficient absorb-no-new-outcome --bound 0.05 $S/unreadable.jsonl   # existing-but-unreadable log: exit 2"
"$GATES" --sufficient absorb-no-new-outcome --bound 0.05 "$S/unreadable.jsonl"; echo "exit=$?"
say "$GATES $S/unreadable.jsonl   # ordinary mode keeps exit 0 on the same log"
"$GATES" "$S/unreadable.jsonl" >/dev/null; echo "exit=$?"
say "$GATES --sufficient absorb-no-new-outcome --bound 0.05 $S/absent.jsonl   # absent log: not yet, exit 1"
"$GATES" --sufficient absorb-no-new-outcome --bound 0.05 "$S/absent.jsonl" | tail -2; echo "exit=${PIPESTATUS[0]}"

say "cat $S/.branch-shadow-truth.jsonl | head -3 ; wc -l   # sidecar written from live reads"
head -3 "$S/.branch-shadow-truth.jsonl"; wc -l < "$S/.branch-shadow-truth.jsonl"

say "# adversarial: tear down every t1 record, rescore - counts must hold via the sidecar and no new lines"
rm -f "$S/t1.meta" "$S/t1.status"
"$GATES" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 30 | tail -2; echo "exit=${PIPESTATUS[0]}"
echo "sidecar lines after teardown: $(wc -l < "$S/.branch-shadow-truth.jsonl")"

say "# adversarial: a fresh wake whose task was torn down before any scoring run stays unreadable"
printf 'id=t2\nwindow=fm-t2\nbackend=tmux\n' > "$S/t2.meta"
mk_rec t2 '1702:1' 0.9 500
rm -f "$S/t2.meta"
"$GATES" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 30 | grep -E '^\| absorb-no-new-outcome \| 6|torn down|^sufficiency: absorb'
echo "sidecar lines: $(wc -l < "$S/.branch-shadow-truth.jsonl")   (still no t2 line: $(grep -c 1702:1 "$S/.branch-shadow-truth.jsonl"))"

echo; echo "===================== when-watch: the documented arming, live ====================="
# Documented arming from docs/claude-supervision-branch.md, with a fast poll so
# the run finishes in seconds instead of an hour.
say "when arm shadow-sufficient-5pct --interval 0.5 --stable 1 --deadline 7776000 --condition-timeout 1800 --condition \"\$PWD/bin/fm-branch-shadow-gates.sh\" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 30 --action bin/fm-branch-shadow-sufficient-notify.sh absorb-no-new-outcome 0.05 shadow-sufficient-5pct"
cd "$ROOT" || exit 1
when arm shadow-sufficient-5pct --interval 0.5 --stable 1 --deadline 7776000 --condition-timeout 1800 \
  --condition "$PWD/bin/fm-branch-shadow-gates.sh" --sufficient absorb-no-new-outcome --bound 0.05 --min-positives 30 \
  --action bin/fm-branch-shadow-sufficient-notify.sh absorb-no-new-outcome 0.05 shadow-sufficient-5pct
say "pe reconcile   # starts the real runner"
pe reconcile
res=''
for _ in $(seq 1 300); do
  for g in "$S/procevent-inbox/when-shadow-sufficient-5pct".*.result; do [ -e "$g" ] && res=$g; done
  [ -n "$res" ] && break; sleep 0.1
done
say "cat $res"
cat "$res"
say "when classify $res"
when classify "$res"
say "cat $S/.wake-queue   # the check wake the action appended"
cat "$S/.wake-queue"
say "when retire shadow-sufficient-5pct"
when retire shadow-sufficient-5pct

echo; echo "===================== when-watch: not-yet bound never fires ====================="
say "when arm shadow-sufficient-1pct ... --bound 0.01 (upper 0.0487 > 0.01, so the condition stays 1)"
when arm shadow-sufficient-1pct --interval 0.5 --stable 1 --deadline 7776000 --condition-timeout 1800 \
  --condition "$PWD/bin/fm-branch-shadow-gates.sh" --sufficient absorb-no-new-outcome --bound 0.01 --min-positives 30 \
  --action bin/fm-branch-shadow-sufficient-notify.sh absorb-no-new-outcome 0.01 shadow-sufficient-1pct
pe reconcile
sleep 6
echo "results for 1pct after 6s: $(ls "$S/procevent-inbox/" 2>/dev/null | grep -c when-shadow-sufficient-1pct)"
echo "wake-queue rows naming shadow-sufficient-1pct: $(grep -c shadow-sufficient-1pct "$S/.wake-queue")"
say "when retire shadow-sufficient-1pct"
when retire shadow-sufficient-1pct
pe reconcile >/dev/null 2>&1
sleep 1

echo; echo "===================== when-watch: read error surfaces as condition-error ====================="
say "when arm shadow-sufficient-err --error-budget 2 --condition ... $S/unreadable.jsonl"
when arm shadow-sufficient-err --interval 0.3 --stable 1 --error-budget 2 --condition-timeout 1800 \
  --condition "$PWD/bin/fm-branch-shadow-gates.sh" --sufficient absorb-no-new-outcome --bound 0.05 "$S/unreadable.jsonl" \
  --action bin/fm-branch-shadow-sufficient-notify.sh absorb-no-new-outcome 0.05 shadow-sufficient-err
pe reconcile
res=''
for _ in $(seq 1 300); do
  for g in "$S/procevent-inbox/when-shadow-sufficient-err".*.result; do [ -e "$g" ] && res=$g; done
  [ -n "$res" ] && break; sleep 0.1
done
say "cat $res"; cat "$res"
echo "wake-queue rows naming shadow-sufficient-err: $(grep -c shadow-sufficient-err "$S/.wake-queue")"
when retire shadow-sufficient-err

echo; echo "===================== notify action alone ====================="
say "bin/fm-branch-shadow-sufficient-notify.sh   # no args: exit 2"
bin/fm-branch-shadow-sufficient-notify.sh; echo "exit=$?"
say "bin/fm-branch-shadow-sufficient-notify.sh absorb-no-new-outcome 0.05 'bad key/..'   # exit 2"
bin/fm-branch-shadow-sufficient-notify.sh absorb-no-new-outcome 0.05 'bad key/..'; echo "exit=$?"
say "bin/fm-branch-shadow-sufficient-notify.sh absorb-no-new-outcome,candidate-order 0.02 shadow-sufficient-2pct   # exit 0, appends one wake"
bin/fm-branch-shadow-sufficient-notify.sh absorb-no-new-outcome,candidate-order 0.02 shadow-sufficient-2pct; echo "exit=$?"
tail -1 "$S/.wake-queue"

pe sweep-home >/dev/null 2>&1
pkill -f "[f]m-procevent-when.sh run when-shadow-sufficient" 2>/dev/null
echo; echo "== done; home $H"
