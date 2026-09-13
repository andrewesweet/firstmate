#!/usr/bin/env bash
# Manual end-to-end demo: drive the real hold/answer, reply-settle and wake
# acknowledge entrypoints in disposable homes with a recording fake curl and
# print the OTLP payloads each posts. Run from the repo root.
set -u
ROOT=$(pwd)
. tests/lib.sh
. tests/wake-helpers.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-return-path-demo)
TASKS_AXI_BIN=$(command -v tasks-axi)
tasks_in() { local h=$1; shift; (cd "$h" && tasks-axi "$@"); }
mkfakecurl() { cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' <%s>' "$@"; printf '\n'; cat; printf '\n--BODY-END--\n'; } >> "$FM_FAKE_CURL_LOG"
exit 0
SH
chmod +x "$1/curl"; }
show() { echo; echo "### $1 (curl log: $(grep -c '^ARGS:' "$2" || true) POST(s))"; awk '/^ARGS:/{print "curl" substr($0,6); next} /^--BODY-END--$/{next} {print}' "$2" | sed 's/^{/&/' | while IFS= read -r l; do case $l in curl*) echo "$l";; *) echo "$l" | jq . ;; esac; done; }

# --- firstmate.hold ---
home="$TMP_ROOT/hold"; mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"; printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fakebin=$(fm_fakebin "$home"); fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi; mkfakecurl "$fakebin"
printf '%s\n' "$$" > "$home/state/.lock"; printf '%s on\n' "$$" > "$home/state/.trace-context-effective"
run_captain() { PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_CURL_LOG="$home/curl.log" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
tasks_in "$home" add traced-call "Traced captain question" --kind captain --repo sample --start >/dev/null
fm_write_meta "$home/state/traced-call.meta" "window=firstmate:traced-call" "traceparent=00-11111111111111111111111111111112-3333333333333334-01" "project=$home/projects/sample" "kind=ship" "harness=codex"
echo '$ fm-captain-hold.sh hold traced-call --reason "captain must choose the export shape"   # at 2026-06-01T12:00:00Z'
FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z run_captain hold traced-call --reason "captain must choose the export shape"
echo "posts so far: $(grep -c '^ARGS:' "$home/curl.log" 2>/dev/null || echo 0)   # hold itself emits nothing"
printf 'Captain chose the wide export.\n' > "$home/wide.txt"
echo '$ fm-captain-hold.sh answer traced-call --decision-file wide.txt'
run_captain answer traced-call --decision-file "$home/wide.txt"
show "firstmate.hold after answer" "$home/curl.log"
echo '$ fm-captain-hold.sh answer traced-call --decision-file wide.txt   # idempotent replay'
run_captain answer traced-call --decision-file "$home/wide.txt"
echo "posts after replay: $(grep -c '^ARGS:' "$home/curl.log")   # replay emits no second span"

# --- firstmate.reply ---
rhome="$TMP_ROOT/reply"; rstate="$rhome/state"; mkdir -p "$rstate" "$rhome/fakebin"; mkfakecurl "$rhome/fakebin"
printf '%s\n' "$$" > "$rstate/.lock"; printf '%s on\n' "$$" > "$rstate/.trace-context-effective"
fm_write_meta "$rstate/hibit.meta" "window=firstmate:hibit" "traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbc-01"
export FM_PENDING_REPLY_NOW=5000
corr=$(fm_pending_reply_create "$rhome" "$rstate" hibit "audit the ledger"); fm_pending_reply_mark_delivered "$rstate" "$corr"
printf 'done [corr=%s]: ledger clean\n' "$corr" > "$rstate/hibit.status"
echo; echo "\$ secondmate hibit writes status: done [corr=$corr]: ledger clean; parent runs fm_pending_reply_try_resolve"
FM_FAKE_CURL_LOG="$rhome/curl.log" PATH="$rhome/fakebin:$PATH" fm_pending_reply_try_resolve "$rstate" "$corr" && echo "resolved: phase=$(fm_pending_reply_get "$rstate/pending-reply/$corr" phase 2>/dev/null || echo resolved)"
show "firstmate.reply after settlement" "$rhome/curl.log"
FM_PENDING_REPLY_NOW=6000 FM_FAKE_CURL_LOG="$rhome/curl.log" PATH="$rhome/fakebin:$PATH" fm_pending_reply_try_resolve "$rstate" "$corr"
echo "posts after resolve replay: $(grep -c '^ARGS:' "$rhome/curl.log")"
unset FM_PENDING_REPLY_NOW

# --- firstmate.wake ---
dir=$(make_case wake); state="$dir/state"; mkfakecurl "$dir/fakebin"
printf '%s\n' "$$" > "$state/.lock"; printf '%s on\n' "$$" > "$state/.trace-context-effective"
fm_write_meta "$state/traced.meta" "window=firstmate:traced" "traceparent=00-cccccccccccccccccccccccccccccccd-dddddddddddddddd-01"
append_wake "$state" signal traced.status "signal: $state/traced.status"
append_wake "$state" stale "firstmate:traced" "stale: firstmate:traced"
append_wake "$state" check startup-network "check: startup-network still pending"
append_wake "$state" heartbeat heartbeat heartbeat
echo; echo '$ cat state/.wake-queue'; cat "$state/.wake-queue"
echo '$ fm-wake-drain.sh   # presentation'
FM_FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" 2> "$dir/drain.err"; grep WAKE_ACK_REQUIRED "$dir/drain.err"
echo "posts after presentation: $(grep -c '^ARGS:' "$dir/curl.log" 2>/dev/null || echo 0)   # per-poll presentation emits nothing"
seq=$(sed -n 's/.*--ack-through \([0-9]*\) .*/\1/p' "$dir/drain.err"); gen=$(sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/drain.err")
echo "\$ fm-wake-drain.sh --ack-through $seq --recovery-generation $gen"
FM_FAKE_CURL_LOG="$dir/curl.log" PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen"
echo "queue after ack: $(wc -c < "$state/.wake-queue") bytes"
show "firstmate.wake after acknowledgement (1 of 4 rows task-keyed; stale/check/heartbeat silent)" "$dir/curl.log"
rm -rf "$TMP_ROOT"
