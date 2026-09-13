#!/usr/bin/env bash
# Manual end-to-end demo: hold a traced captain call, answer it, show the
# firstmate.hold span the close posts; replay the answer and show nothing more.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-hold-demo); trap 'rm -rf -- "$TMP_ROOT"' EXIT
TASKS_AXI_BIN=$(command -v tasks-axi)
home="$TMP_ROOT/demo"
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fakebin=$(fm_fakebin "$home"); fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
{ printf 'curl'; printf ' %s' "$@"; printf '\n'; cat; printf '\n'; } >> "$FM_FAKE_CURL_LOG"
SH
chmod +x "$fakebin/curl"
export FM_FAKE_CURL_LOG="$home/curl.log"
printf '%s\n' "$$" > "$home/state/.lock"
printf '%s on\n' "$$" > "$home/state/.trace-context-effective"
captain() { PATH="$fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
(cd "$home" && tasks-axi add demo-call "Demo captain question" --kind captain --repo sample --start >/dev/null)
fm_write_meta "$home/state/demo-call.meta" "window=firstmate:demo-call" \
  "traceparent=00-0123456789abcdef0123456789abcdef-fedcba9876543210-01" "kind=ship" "harness=codex"
echo '### hold at 2026-06-01T12:00:00Z'
FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z captain hold demo-call --reason "captain must choose the export shape"
echo; echo '### answer'
printf 'Captain chose the wide export.\n' > "$home/wide.txt"
captain answer demo-call --decision-file "$home/wide.txt"
echo; echo '### span posted by the answer (start = recorded hold-set time)'
grep '^curl' "$home/curl.log"
grep -v '^curl' "$home/curl.log" | jq '.resourceSpans[0].scopeSpans[0].spans[0] | {name, traceId, parentSpanId, start: (.startTimeUnixNano|tonumber/1e9|todate), attributes: [.attributes[] | {(.key): .value.stringValue}] | add}'
echo; echo '### idempotent answer replay'
captain answer demo-call --decision-file "$home/wide.txt"
echo "curl calls total: $(grep -c '^curl' "$home/curl.log")"
