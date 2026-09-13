#!/usr/bin/env bash
# Manual end-to-end demo: drive the real hold/answer, reply-settle, and
# wake-drain entrypoints with a recording fake curl (OTLP receiver stand-in)
# and print every span payload actually posted, plus the negative cases.
set -u
ROOT=${ROOT:?worktree root}
EV=${EV:?evidence dir}
cd "$ROOT"
. tests/wake-helpers.sh
. bin/fm-pending-reply-lib.sh
TMP_ROOT=$(fm_test_tmproot fm-return-span-demo)
export TMP_ROOT
mkfakecurl() { cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' <%s>' "$@"; printf '\n'; cat; printf '\n--BODY-END--\n'; } >> "${FM_FAKE_CURL_LOG:?}"
exit 0
SH
chmod +x "$1/curl"; }
show_spans() {  # <curl.log>
  local n=0
  [ -s "$1" ] || { echo "  (no span posted)"; return; }
  awk '/^ARGS:/{next} /^--BODY-END--$/{print ""; next} {printf "%s", $0}' "$1" | while IFS= read -r body; do
    [ -n "$body" ] || continue
    n=$((n+1))
    echo "  span #$n:"
    jq '.resourceSpans[0] | {resource: [.resource.attributes[] | {(.key): .value.stringValue}] | add,
      span: (.scopeSpans[0].spans[0] | {name, traceId, parentSpanId, startTimeUnixNano, endTimeUnixNano,
        attributes: ([.attributes[] | {(.key): .value.stringValue}] | add)})}' <<< "$body" | sed 's/^/    /'
  done
}
hr() { printf '\n===== %s =====\n' "$1"; }

# ---------------------------------------------------------------- hold
hr "firstmate.hold: hold -> answer on a traced captain call"
home="$TMP_ROOT/hold"; mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp .tasks.toml "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fakebin=$(fm_fakebin "$home"); fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
mkfakecurl "$fakebin"
printf '%s\n' "$$" > "$home/state/.lock"
printf '%s on\n' "$$" > "$home/state/.trace-context-effective"
export FM_FAKE_CURL_LOG="$home/curl.log"; : > "$FM_FAKE_CURL_LOG"
captain() { PATH="$fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  bin/fm-captain-hold.sh "$@"; }
(cd "$home" && tasks-axi add traced-call "Traced captain question" --kind captain --repo sample --start) >/dev/null
fm_write_meta "$home/state/traced-call.meta" "window=firstmate:traced-call" \
  "traceparent=00-11111111111111111111111111111112-3333333333333334-01" "project=$home/projects/sample" "kind=ship" "harness=codex"
echo '$ fm-captain-hold.sh hold traced-call --reason "captain must choose the export shape"   (at 2026-06-01T12:00:00Z)'
FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z captain hold traced-call --reason "captain must choose the export shape"
echo "posted so far:"; show_spans "$FM_FAKE_CURL_LOG"
printf 'Captain chose the wide export.\n' > "$home/wide.txt"
echo '$ fm-captain-hold.sh answer traced-call --decision-file wide.txt'
captain answer traced-call --decision-file "$home/wide.txt"
show_spans "$FM_FAKE_CURL_LOG"
echo '$ fm-captain-hold.sh answer traced-call --decision-file wide.txt   (idempotent replay)'
captain answer traced-call --decision-file "$home/wide.txt"
echo "span count after replay: $(grep -c '^ARGS:' "$FM_FAKE_CURL_LOG")"

hr "firstmate.hold: --origin call joins the origin task's trace; --release close mode"
(cd "$home" && tasks-axi add traced-origin "Origin work" --kind ship --repo sample --start) >/dev/null
fm_write_meta "$home/state/traced-origin.meta" "window=firstmate:traced-origin" \
  "traceparent=00-66666666666666666666666666666667-8888888888888889-01" "project=$home/projects/sample" "kind=ship" "harness=codex"
: > "$FM_FAKE_CURL_LOG"
echo '$ fm-captain-hold.sh hold origin-call --title "Question from the origin" --origin traced-origin --reason "origin needs a ruling"'
FM_CAPTAIN_HOLD_NOW=2026-06-01T13:00:00Z captain hold origin-call --title "Question from the origin" --origin traced-origin --reason "origin needs a ruling"
printf 'Ruled.\n' > "$home/ruled.txt"
echo '$ fm-captain-hold.sh answer origin-call --decision-file ruled.txt'
captain answer origin-call --decision-file "$home/ruled.txt"
show_spans "$FM_FAKE_CURL_LOG"
: > "$FM_FAKE_CURL_LOG"
echo '$ fm-captain-hold.sh hold traced-origin --reason "pause"; answer traced-origin --decision-file go.txt --release'
FM_CAPTAIN_HOLD_NOW=2026-06-01T14:00:00Z captain hold traced-origin --reason "pause"
printf "Go.\n" > "$home/go.txt"; captain answer traced-origin --decision-file "$home/go.txt" --release
show_spans "$FM_FAKE_CURL_LOG"

# ---------------------------------------------------------------- reply
hr "firstmate.reply: delivered secondmate request -> correlated settlement in parent home"
phome="$TMP_ROOT/parent"; mkdir -p "$phome/state" "$phome/fakebin"; mkfakecurl "$phome/fakebin"
printf '%s\n' "$$" > "$phome/state/.lock"; printf '%s on\n' "$$" > "$phome/state/.trace-context-effective"
fm_write_meta "$phome/state/hibit.meta" "window=firstmate:hibit" "traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-cccccccccccccccd-01"
export FM_PENDING_REPLY_NOW=5000
corr=$(fm_pending_reply_create "$phome" "$phome/state" hibit "audit the ledger")
echo "created pending reply corr=$corr (created at epoch 5000)"
FM_PENDING_REPLY_NOW=5100 fm_pending_reply_mark_delivered "$phome/state" "$corr"
echo "marked delivered at epoch 5100"
printf 'done [corr=%s]: ledger clean\n' "$corr" > "$phome/state/hibit.status"
echo "secondmate status line: $(cat "$phome/state/hibit.status")"
export FM_FAKE_CURL_LOG="$phome/curl.log"; : > "$FM_FAKE_CURL_LOG"
FM_PENDING_REPLY_NOW=5200 PATH="$phome/fakebin:$PATH" fm_pending_reply_try_resolve "$phome/state" "$corr" && echo "resolve: ok, phase=$(fm_pending_reply_get "$(fm_pending_reply_path "$phome/state" "$corr")" phase)"
show_spans "$FM_FAKE_CURL_LOG"
FM_PENDING_REPLY_NOW=6000 PATH="$phome/fakebin:$PATH" fm_pending_reply_try_resolve "$phome/state" "$corr"
echo "span count after already-resolved replay: $(grep -c '^ARGS:' "$FM_FAKE_CURL_LOG")"

# ---------------------------------------------------------------- wake
hr "firstmate.wake: task-keyed rows only, one shared acknowledgement instant, teardown survival"
dir=$(make_case wake); state="$dir/state"; mkfakecurl "$dir/fakebin"
printf '%s\n' "$$" > "$state/.lock"; printf '%s on\n' "$$" > "$state/.trace-context-effective"
fm_write_meta "$state/traced.meta" "window=firstmate:traced" "traceparent=00-11111111111111111111111111111112-3333333333333334-01"
fm_write_meta "$state/gone.meta" "window=firstmate:gone" "traceparent=00-99999999999999999999999999999990-7777777777777770-01"
append_wake "$state" signal traced.status "signal: $state/traced.status"
append_wake "$state" stale "firstmate:traced" "stale: firstmate:traced"
append_wake "$state" check startup-network "check: startup-network still pending"
append_wake "$state" heartbeat heartbeat heartbeat
append_wake "$state" signal gone.status "signal: $state/gone.status"
echo "queued rows:"; sed 's/^/  /' "$state/.wake-queue"
export FM_FAKE_CURL_LOG="$dir/curl.log"; : > "$FM_FAKE_CURL_LOG"
echo '$ fm-wake-drain.sh   (presentation)'
PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" bin/fm-wake-drain.sh > "$dir/drain.out" 2> "$dir/drain.err"
sed 's/^/  stdout: /' "$dir/drain.out"; sed 's/^/  stderr: /' "$dir/drain.err"
echo "spans posted by presentation: $(grep -c '^ARGS:' "$FM_FAKE_CURL_LOG")"
echo "capture files beside queue: $(ls -A "$state" | grep '^\.wake-trace' | tr '\n' ' ')"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) .*/\1/p' "$dir/drain.err")
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/drain.err")
echo "tearing down task 'gone' before acknowledgement: rm $state/gone.meta"; rm -f "$state/gone.meta"
echo "\$ fm-wake-drain.sh --ack-through $seq --recovery-generation $gen"
PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen"; echo "  exit=$?"
echo "queue after ack: $(wc -c < "$state/.wake-queue") bytes"
echo "capture files after ack: '$(ls -A "$state" | grep '^\.wake-trace' | tr '\n' ' ')'"
show_spans "$FM_FAKE_CURL_LOG"
echo "distinct endTimeUnixNano across batch: $(awk '/^ARGS:/{next} /^--BODY-END--$/{print ""; next} {printf "%s",$0}' "$FM_FAKE_CURL_LOG" | grep . | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].endTimeUnixNano' | sort -u | wc -l)"
echo "\$ fm-wake-drain.sh --ack-through $seq --recovery-generation $gen   (replay)"
PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen"; echo "  exit=$?"
echo "span count after replay: $(grep -c '^ARGS:' "$FM_FAKE_CURL_LOG")"

hr "default-off: session decision off -> byte-identical behaviour, no span"
dir=$(make_case wake-off); state="$dir/state"; mkfakecurl "$dir/fakebin"
printf '%s\n' "$$" > "$state/.lock"; printf '%s off\n' "$$" > "$state/.trace-context-effective"
fm_write_meta "$state/traced.meta" "window=firstmate:traced" "traceparent=00-11111111111111111111111111111112-3333333333333334-01"
append_wake "$state" signal traced.status "signal: $state/traced.status"
export FM_FAKE_CURL_LOG="$dir/curl.log"; : > "$FM_FAKE_CURL_LOG"
PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" bin/fm-wake-drain.sh > /dev/null 2> "$dir/drain.err"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) .*/\1/p' "$dir/drain.err")
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/drain.err")
PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen"; echo "ack exit=$? queue bytes=$(wc -c < "$state/.wake-queue")"
show_spans "$FM_FAKE_CURL_LOG"
