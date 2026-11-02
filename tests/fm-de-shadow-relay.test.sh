#!/usr/bin/env bash
# Behavior tests for bin/fm-de-shadow-relay.mjs, the Drex Max v1.1 live shadow
# relay (data/de-shadow-drexmax/).
#
# Drives the relay's public CLI and HTTP interface against fake TypeSafe and
# fake Nace endpoints on loopback, and proves:
#   (a) the caller's response is byte-identical to the live upstream's, with
#       the caller's Authorization header forwarded and the token segment
#       stripped from the proxied path;
#   (b) a slow, failing, or crashed Nace never delays or alters the caller's
#       response, and any Nace error lands in the record;
#   (c) no key value appears in any record or relay log;
#   (d) only token-bearing requests are shadowed; wrong or missing tokens are
#       proxied with no Nace call and no record;
#   (e) compaction requests are skipped on a topic hit, on a caller-reported
#       coverage.redacted state, and when the scan config is unavailable -
#       each leaving only a content-free skip line - while the boilerplate
#       filter keeps standard rule-shaped lines from triggering a skip;
#   (f) start is refused without the shadow key, and the lifecycle
#       start/status/stop commands work.
# No case touches the real TypeSafe or Nace endpoints.
set -u

# The relay must resolve its own key from the injected keys file, never from
# the ambient environment.
unset NACE_API_KEY TYPESAFE_API_KEY

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELAY="$ROOT/bin/fm-de-shadow-relay.mjs"
TMP_ROOT=$(fm_test_tmproot fm-de-shadow-relay)
HOME_DIR="$TMP_ROOT/home"
BASE_DIR="$HOME_DIR/data/de-shadow-drexmax"
KEYS_FILE="$TMP_ROOT/keys.env"
# A fake key for the fake Nace endpoint; its absence from records and logs is
# asserted below, so it must be distinctive.
NACE_KEY='FAKE-NACE-KEY-7c4f2e91aabb00dd-never-a-real-key'
TOKEN='tok0123456789abcdef0123456789abcdef'
PORT=$(( 20000 + (RANDOM % 20000) ))
mkdir -p "$HOME_DIR" "$TMP_ROOT/bin"

cat > "$KEYS_FILE" <<EOF
# fake keys file for the relay test
NACE_API_KEY=$NACE_KEY
OTHER_KEY=unused
EOF

# --- fake upstreams: one node process serving both ports ---------------------
# Usage: node fake-upstream.mjs <safe-port> <safe-log> <nace-port> <nace-log>
#   <body-file> <control-file>
# The safe endpoint answers every POST with the body file's exact bytes and
# header "x-fake: live". The nace endpoint reads the control file per request:
#   {}                          answer 200 {"ok":true,"model":"drex-max-v1.1",
#                               "answers":{},"usage":{"input_tokens":10,"output_tokens":0}}
#   {"delayMs":N}               wait N ms before answering
#   {"status":N,"body":"x"}     answer with status N and body x
#   {"crash":true}              destroy the connection
# Both record {path, authorization, body} per request to their log file.
cat > "$TMP_ROOT/bin/fake-upstream.mjs" <<'EOF'
import http from "node:http";
import fs from "node:fs";

const [safePort, safeLog, nacePort, naceLog, bodyFile, controlFile, safeControlFile] = process.argv.slice(2);
const canned = fs.readFileSync(bodyFile);
const shadowBriefs = new Set();

function record(log, entry) {
  fs.appendFileSync(log, `${JSON.stringify(entry)}\n`);
}

function serve(port, log, handler) {
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      record(log, { path: req.url, authorization: req.headers.authorization ?? null, body: Buffer.concat(chunks).toString("utf8") });
      handler(req, res, Buffer.concat(chunks));
    });
    req.on("error", () => {});
  });
  server.listen(Number(port), "127.0.0.1");
}

serve(safePort, safeLog, (req, res, body) => {
  if (req.url.split("?")[0] !== "/v1/systemone") {
    res.writeHead(404);
    res.end("wrong live path");
    return;
  }
  const control = JSON.parse(fs.readFileSync(safeControlFile, "utf8"));
  if (control.crash) {
    res.destroy();
    return;
  }
  if (control.readError) {
    res.writeHead(200, { "content-length": canned.length + 1 });
    res.write(canned);
    setTimeout(() => res.destroy(), 20);
    return;
  }
  const started = Date.now();
  const brief = JSON.parse(body).state?.task?.brief;
  const reply = () => {
    if (control.waitForShadow && !shadowBriefs.has(brief)) {
      if (Date.now() - started < 1000) {
        setTimeout(reply, 10);
        return;
      }
      res.writeHead(503);
      res.end("shadow did not start alongside live");
      return;
    }
    res.writeHead(200, { "content-type": "application/json", "x-fake": "live" });
    res.end(canned);
  };
  if (control.delayMs) setTimeout(reply, control.delayMs);
  else reply();
});

serve(nacePort, naceLog, (req, res, body) => {
  shadowBriefs.add(JSON.parse(body).state?.task?.brief);
  let control = {};
  try {
    control = JSON.parse(fs.readFileSync(controlFile, "utf8"));
  } catch {}
  const reply = () => {
    if (control.crash) {
      res.destroy();
      return;
    }
    const status = control.status ?? 200;
    const body = control.body ?? JSON.stringify({ ok: true, model: "drex-max-v1.1", answers: {}, usage: { input_tokens: 10, output_tokens: 0 } });
    res.writeHead(status, { "content-type": "application/json" });
    res.end(body);
  };
  if (control.delayMs) setTimeout(reply, Number(control.delayMs));
  else reply();
});
EOF

SAFE_PORT=$(( 21000 + (RANDOM % 20000) ))
NACE_PORT=$(( 22000 + (RANDOM % 20000) ))
SAFE_LOG="$TMP_ROOT/fake-safe.log.jsonl"
NACE_LOG="$TMP_ROOT/fake-nace.log.jsonl"
CONTROL_FILE="$TMP_ROOT/nace-control.json"
SAFE_CONTROL_FILE="$TMP_ROOT/safe-control.json"
echo '{}' > "$SAFE_CONTROL_FILE"
echo '{}' > "$CONTROL_FILE"

# The canned live response: unicode-free but with irregular interior spacing,
# trailing whitespace, and no trailing newline, so a byte-for-byte assertion
# catches any normalisation - while staying valid JSON so usage parses.
printf '{ "model": "jev-1.14.0", "answers": { "rule": { "type": "choice", "choice": "rule_2", "confidence": 0.71,\n    "probabilities": { "rule_1": 0.05, "rule_2": 0.71, "default": 0.24 } } },\n  "usage": { "input_tokens": 812, "output_tokens": 60 } }\x20\x20' > "$TMP_ROOT/canned-live.json"

NODE_BIN=$(command -v node)
node "$TMP_ROOT/bin/fake-upstream.mjs" "$SAFE_PORT" "$SAFE_LOG" "$NACE_PORT" "$NACE_LOG" "$TMP_ROOT/canned-live.json" "$CONTROL_FILE" "$SAFE_CONTROL_FILE" &
FAKE_PID=$!
# wait for both fake ports
for i in $(seq 1 50); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$SAFE_PORT") 2>/dev/null && (exec 4<>"/dev/tcp/127.0.0.1/$NACE_PORT") 2>/dev/null; then
    exec 3>&- 4>&- || true
    break
  fi
  sleep 0.1
done

export FM_HOME="$HOME_DIR"
export DE_SHADOW_PORT="$PORT"
export DE_SHADOW_LIVE_TIMEOUT_MS=1500
export DE_SHADOW_NACE_TIMEOUT_MS=8000
export DE_SHADOW_KEYS_FILE="$KEYS_FILE"
export DE_SHADOW_TYPESAFE_BASE="http://127.0.0.1:$SAFE_PORT"
export DE_SHADOW_NACE_BASE="http://127.0.0.1:$NACE_PORT"
export DE_SHADOW_SCAN_FILE="$TMP_ROOT/scan.json"
export DE_SHADOW_TOKEN_FILE="$TMP_ROOT/token"
export DE_SHADOW_PID_FILE="$TMP_ROOT/relay.pid"
export DE_SHADOW_LOG_FILE="$TMP_ROOT/relay-log"

cat > "$TMP_ROOT/scan.json" <<'EOF'
{
  "groups": {
    "topic_a": "TOPICAHITWORD",
    "topic_b": "TOPICBHITWORD"
  },
  "boiler": "BOILERFILTERLINE"
}
EOF
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"

kill_relay() {
  if [ -f "$TMP_ROOT/relay.pid" ]; then
    FM_HOME="$HOME_DIR" "$NODE_BIN" "$RELAY" stop >/dev/null 2>&1 || true
  fi
}
trap 'kill_relay; kill "$FAKE_PID" 2>/dev/null || true; fm_test_cleanup' EXIT

# wait_for <pattern> <file> <msg>: poll up to 10s for a fixed-string record.
wait_for() {
  local pattern=$1 file=$2 msg=$3 i
  for i in $(seq 1 100); do
    [ -f "$file" ] && grep -F -- "$pattern" "$file" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "$msg (pattern not found within 10s in $file)"
}

now_ms() {
  node -e 'process.stdout.write(String(Date.now()))'
}

records() {
  [ -f "$BASE_DIR/shadow/shadow.jsonl" ] && cat "$BASE_DIR/shadow/shadow.jsonl" || printf ''
}

post() {  # <path> <body-file> -> body written to stdout-referred file $4? no: writes to $TMP_ROOT/reply.bin; echoes http code
  local path=$1 body=$2
  curl -sS --max-time 10 -o "$TMP_ROOT/reply.bin" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT$path" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer CALLER-TYPESAFE-KEY" \
    --data-binary "@$body" 2>/dev/null
}

routing_body() {  # <file> <marker>
  cat > "$1" <<EOF
{"model":"jev-1.14.0","state":{"task":{"project":"demo","brief":"plain brief $2"}},"questions":{"rule":{"type":"choice","instructions":"pick","criteria":{"rule_1":"a","default":"none"}}}}
EOF
}

compaction_body() {  # <file> <extra-state-json> <marker>
  cat > "$1" <<EOF
{"model":"jev-1.14.0","state":{"userConstraints":[{"role":"user","text":"work note $3"}],"recent":[{"role":"assistant","text":"progress line $3"}],"coverage":{"redacted":false}},"questions":{"done":{"type":"choice","instructions":"done?","criteria":{"finished":"y","not_finished":"n","unclear":"u"}},"shape":{"type":"choice","instructions":"shape?","criteria":{"hands_on":"h","coordinating":"c","unclear":"u"}}}}
EOF
}

# --- lifecycle: refused start without keys, then a running relay --------------

start_relays() {
  FM_HOME="$HOME_DIR" "$NODE_BIN" "$RELAY" start --port "$PORT" >/dev/null 2>&1
}

# no relay yet: start must be refused when the keys file is missing
start_code=0
FM_HOME="$HOME_DIR" DE_SHADOW_KEYS_FILE="$TMP_ROOT/no-such-keys.env" DE_SHADOW_TOKEN_FILE="$TMP_ROOT/token2" DE_SHADOW_PID_FILE="$TMP_ROOT/relay2.pid" \
  "$NODE_BIN" "$RELAY" start --port $(( PORT + 1 )) >/dev/null 2>&1 || start_code=$?
expect_code 2 "$start_code" "start is refused without the shadow key"
sleep 0.3
if (exec 3<>"/dev/tcp/127.0.0.1/$(( PORT + 1 ))") 2>/dev/null; then
  exec 3>&- || true
  fail "a refused start must not leave a relay listening"
fi
pass "start is refused without the shadow key and leaves no listener"

start_relays || fail "relay start failed"
FM_HOME="$HOME_DIR" "$NODE_BIN" "$RELAY" status >/dev/null 2>&1 || fail "relay status after start"
pass "start daemonizes and status reports running"
original_runtime=$(cat "$TMP_ROOT/relay.pid")
original_pid=$(jq -r '.pid' "$TMP_ROOT/relay.pid")
repeat_output=$("$NODE_BIN" "$RELAY" start --port "$PORT") || fail "repeated start failed"
assert_contains "$repeat_output" "already-running 127.0.0.1:$PORT" "repeated start identifies the running port"
assert_equals "$original_runtime" "$(cat "$TMP_ROOT/relay.pid")" "repeated start preserves the original runtime record"
status_output=$("$NODE_BIN" "$RELAY" status) || fail "repeated start broke status"
assert_contains "$status_output" "pid=$original_pid " "status retains the original live pid"
pass "repeated start preserves ownership of the running daemon"

# --- (a) routing pair: byte-identical live response, token stripped, pair recorded

routing_body "$TMP_ROOT/routing-1.json" one
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/routing-1.json")
expect_code 200 "$http" "token-bearing routing call reaches the live upstream"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "the caller's response is not byte-identical to the live upstream's"
wait_for '"use":"routing"' "$BASE_DIR/shadow/shadow.jsonl" "routing pair is recorded"
rec=$(grep -F '"use":"routing"' "$BASE_DIR/shadow/shadow.jsonl" | head -1)
assert_contains "$rec" '"request":"{\"model\":\"jev-1.14.0\"' "the full request body is recorded"
assert_contains "$rec" '"live":{"status":200,"ms":' "the live status and latency are recorded"
assert_contains "$rec" '"usage":{"input_tokens":812,"output_tokens":60}' "the live billed tokens are recorded"
assert_contains "$rec" '"shadow":{"status":200,"ms":' "the shadow status and latency are recorded"
assert_contains "$rec" '"error":null' "a clean pair carries a null shadow error"
assert_equals "$(jq -c '.live.usage' "$BASE_DIR/shadow/shadow.jsonl" | head -1)" '{"input_tokens":812,"output_tokens":60}' "live usage is parsed into the record"
live=$(jq -c '.live.body' "$BASE_DIR/shadow/shadow.jsonl" | head -1)
assert_contains "$live" 'jev-1.14.0' "the live response body is recorded"
safe_request=$(head -1 "$SAFE_LOG")
assert_contains "$safe_request" '"path":"/v1/systemone"' "the token segment is stripped from the proxied path"
assert_contains "$safe_request" '"authorization":"Bearer CALLER-TYPESAFE-KEY"' "the caller's Authorization header is forwarded unchanged"
assert_contains "$safe_request" '"authorization":"Bearer CALLER-TYPESAFE-KEY"' "the caller's Authorization header is forwarded unchanged"
jq -j '.body' <<<"$safe_request" | cmp -s - "$TMP_ROOT/routing-1.json" || fail "the request body is not forwarded byte for byte"
nace_request=$(head -1 "$NACE_LOG")
assert_equals 'drex-max-v1.1' "$(jq -r '.body | fromjson | .model' <<<"$nace_request")" "the shadow call swaps the model id"
assert_not_equals 'jev-1.14.0' "$(jq -r '.body | fromjson | .model' <<<"$nace_request")" "the shadow call carries no live model id"
assert_equals 'plain brief one' "$(jq -r '.body | fromjson | .state.task.brief' <<<"$nace_request")" "the shadow call forwards the same request content"
assert_equals "$(jq -r '.authorization' "$NACE_LOG" | head -1)" "Bearer $NACE_KEY" "the shadow call authenticates with the keys-file Nace key"
assert_contains "$nace_request" '"path":"/v1/systemone"' "the shadow call hits the Nace systemone endpoint"
pass "a routing call is proxied byte for byte and paired with a model-swapped shadow call"

echo '{"waitForShadow":true}' > "$SAFE_CONTROL_FILE"
routing_body "$TMP_ROOT/parallel.json" parallel
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/parallel.json")
expect_code 200 "$http" "the shadow starts before the live response can finish"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "parallel execution altered the live bytes"
wait_for '\"brief\":\"plain brief parallel\"' "$BASE_DIR/shadow/shadow.jsonl" "the parallel pair is recorded"
echo '{}' > "$SAFE_CONTROL_FILE"
pass "the live upstream can wait for the shadow request without deadlocking"

# --- (b) slow or failing Nace never delays or alters the caller --------------

# slow Nace: the caller still gets the identical bytes quickly
echo '{"delayMs":1500}' > "$CONTROL_FILE"
routing_body "$TMP_ROOT/routing-2.json" two
t0=$(now_ms)
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/routing-2.json")
t1=$(now_ms)
elapsed_ms=$(( t1 - t0 ))
expect_code 200 "$http" "slow Nace leaves the live status untouched"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "slow Nace altered the caller's response bytes"
[ "$elapsed_ms" -lt 1200 ] || fail "slow Nace delayed the caller (${elapsed_ms} ms)"
wait_for '\"brief\":\"plain brief two\"' "$BASE_DIR/shadow/shadow.jsonl" "slow-Nace pair is recorded"
slow_rec=$(grep -F '\"brief\":\"plain brief two\"' "$BASE_DIR/shadow/shadow.jsonl" | head -1)
slow_ms=$(printf '%s' "$slow_rec" | jq -r '.shadow.ms')
[ "$slow_ms" -ge 1500 ] || fail "the record understates the slow shadow latency ($slow_ms ms)"
assert_contains "$slow_rec" '"error":null' "a slow but successful shadow carries no error"

# failing Nace (http 500): caller unaffected, error recorded
echo '{"status":500,"body":"{\"error\":\"boom\"}"}' > "$CONTROL_FILE"
routing_body "$TMP_ROOT/routing-3.json" three
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/routing-3.json")
expect_code 200 "$http" "a failing Nace leaves the live status untouched"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "a failing Nace altered the caller's response bytes"
wait_for '\"brief\":\"plain brief three\"' "$BASE_DIR/shadow/shadow.jsonl" "failed-Nace pair is recorded"
fail_rec=$(grep -F '\"brief\":\"plain brief three\"' "$BASE_DIR/shadow/shadow.jsonl" | head -1)
assert_contains "$fail_rec" '"status":500' "the Nace error status is recorded"
assert_contains "$fail_rec" '"error":"http 500"' "a non-2xx shadow answer is recorded as an error"

# crashed Nace (connection destroyed): caller unaffected, transport error recorded
echo '{"crash":true}' > "$CONTROL_FILE"
routing_body "$TMP_ROOT/routing-4.json" four
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/routing-4.json")
expect_code 200 "$http" "a crashed Nace leaves the live status untouched"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "a crashed Nace altered the caller's response bytes"
wait_for '\"brief\":\"plain brief four\"' "$BASE_DIR/shadow/shadow.jsonl" "crashed-Nace pair is recorded"
crash_rec=$(grep -F '\"brief\":\"plain brief four\"' "$BASE_DIR/shadow/shadow.jsonl" | head -1)
assert_not_contains "$crash_rec" '"error":null' "a crashed shadow call is recorded as an error"
echo '{}' > "$CONTROL_FILE"
pass "a slow, failing, or crashed Nace never delays or alters the caller, and its error lands in the record"

for live_failure in crash readError delayMs; do
  case "$live_failure" in
    crash) echo '{"crash":true}' > "$SAFE_CONTROL_FILE"; expected_status=502 ;;
    readError) echo '{"readError":true}' > "$SAFE_CONTROL_FILE"; expected_status=502 ;;
    delayMs) echo '{"delayMs":2000}' > "$SAFE_CONTROL_FILE"; expected_status=504 ;;
  esac
  routing_body "$TMP_ROOT/live-failure.json" "live-$live_failure"
  http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/live-failure.json")
  expect_code "$expected_status" "$http" "a live $live_failure retains its caller error"
  marker="plain brief live-$live_failure"
  wait_for "$marker" "$BASE_DIR/shadow/shadow.jsonl" "a live $live_failure still records a pair"
  live_failure_rec=$(jq -c --arg marker "$marker" 'select(.request | fromjson | .state.task.brief == $marker)' "$BASE_DIR/shadow/shadow.jsonl")
  assert_equals 1 "$(printf '%s\n' "$live_failure_rec" | wc -l | tr -d ' ')" "a live $live_failure records exactly one pair"
  assert_equals null "$(jq -r '.live.status' <<<"$live_failure_rec")" "a live $live_failure has no upstream status"
  [ "$(jq -r '.live.error | length' <<<"$live_failure_rec")" -gt 0 ] || fail "missing live error"
  assert_equals 200 "$(jq -r '.shadow.status' <<<"$live_failure_rec")" "a live $live_failure retains the settled shadow result"
done
echo '{}' > "$SAFE_CONTROL_FILE"
pass "live transport failures, read failures, and timeouts retain one shadow pair"

# --- (d) only token-bearing requests are shadowed -----------------------------

lines_before=$(records | wc -l | tr -d ' ')
nace_lines_before=$(cat "$NACE_LOG" | wc -l | tr -d ' ')
routing_body "$TMP_ROOT/routing-5.json" five
http=$(post "/v1/systemone" "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a token-less call still reaches the live upstream"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "a token-less call is not proxied byte for byte"
http=$(post "/wrongtoken12345678901234567890/v1/systemone" "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a wrong-token call still reaches the live upstream"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "a wrong token altered the live bytes"
assert_equals '/v1/systemone' "$(tail -1 "$SAFE_LOG" | jq -r '.path')" "a wrong token is stripped before proxying"
sleep 0.3
assert_equals "$lines_before" "$(records | wc -l | tr -d ' ')" "token-less and wrong-token calls record nothing"
assert_equals "$nace_lines_before" "$(wc -l < "$NACE_LOG" | tr -d ' ')" "token-less and wrong-token calls never reach Nace"
http=$(post "/$TOKEN/v1/systemone?case=current" "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a current token preserves query routing"
assert_equals '/v1/systemone?case=current' "$(tail -1 "$SAFE_LOG" | jq -r '.path')" "a current token preserves the query string"
wait_for 'plain brief five' "$BASE_DIR/shadow/shadow.jsonl" "the current token with a query still shadows"
lines_before=$(records | wc -l | tr -d ' ')
nace_lines_before=$(wc -l < "$NACE_LOG" | tr -d ' ')
printf '%s\n' 'rotated0123456789abcdef0123456789abcdef' > "$TMP_ROOT/token"
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a stale token preserves the ordinary live endpoint"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "a stale token altered the live bytes"
assert_equals '/v1/systemone' "$(tail -1 "$SAFE_LOG" | jq -r '.path')" "rotation preserves the plain live path"
http=$(post "/$TOKEN/v1/systemone?case=rotated" "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a stale token still reaches the live upstream"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "rotation altered the live bytes"
assert_equals '/v1/systemone?case=rotated' "$(tail -1 "$SAFE_LOG" | jq -r '.path')" "a stale token is stripped and the query survives"
rm "$TMP_ROOT/token"
http=$(post "/$TOKEN/v1/systemone?case=deleted" "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a deleted token still reaches the live upstream"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "token deletion altered the live bytes"
assert_equals '/v1/systemone?case=deleted' "$(tail -1 "$SAFE_LOG" | jq -r '.path')" "a deleted token is stripped and the query survives"
http=$(post '/v1/systemone?case=bare' "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a bare path with a query reaches the live upstream"
assert_equals '/v1/systemone?case=bare' "$(tail -1 "$SAFE_LOG" | jq -r '.path')" "a bare path and query remain unchanged"
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"
sleep 0.5
assert_equals "$lines_before" "$(records | wc -l | tr -d ' ')" "stale, deleted, and bare tokens record nothing"
assert_equals "$nace_lines_before" "$(cat "$NACE_LOG" | wc -l | tr -d ' ')" "stale, deleted, and bare tokens never reach Nace"
pass "only the token-bearing path is shadowed; any other caller is proxied with no shadow effect"

# --- (e) compaction content gate ----------------------------------------------

# clean compaction request shadows
compaction_body "$TMP_ROOT/comp-1.json" '' clean
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/comp-1.json")
expect_code 200 "$http" "a clean compaction call reaches the live upstream"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "a compaction call is not proxied byte for byte"
wait_for '"use":"compaction"' "$BASE_DIR/shadow/shadow.jsonl" "a clean compaction pair is recorded"
assert_not_contains "$(records)" '"skipped"' "a clean compaction pair is not a skip"

# topic hit: no Nace call, no request content, only a skip line
compaction_body "$TMP_ROOT/comp-2.json" '' 'mentioning TOPICAHITWORD in passing'
nace_lines_before=$(cat "$NACE_LOG" | wc -l | tr -d ' ')
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/comp-2.json")
expect_code 200 "$http" "a topic-hit compaction call still reaches the live upstream"
wait_for '"skipped":"topic"' "$BASE_DIR/shadow/shadow.jsonl" "a topic hit records a skip line"
skip_rec=$(grep -F '"skipped":"topic"' "$BASE_DIR/shadow/shadow.jsonl" | head -1)
assert_contains "$skip_rec" '"groups":["topic_a"]' "the hit topic group is named"
assert_not_contains "$skip_rec" '"request"' "a skip line carries no request content"
assert_not_contains "$skip_rec" '"live"' "a skip line carries no response content"
sleep 0.3
assert_equals "$nace_lines_before" "$(cat "$NACE_LOG" | wc -l | tr -d ' ')" "a topic-hit request never reaches Nace"

# boilerplate filter: a secrets-rule line alone must not skip
topic_skips_before=$(grep -c '"skipped":"topic"' "$BASE_DIR/shadow/shadow.jsonl" || true)
cat > "$TMP_ROOT/comp-3.json" <<'EOF'
{"model":"jev-1.14.0","state":{"userConstraints":[{"role":"user","text":"BOILERFILTERLINE: never print secrets"}],"recent":[{"role":"assistant","text":"acknowledged"}],"coverage":{"redacted":false}},"questions":{"done":{"type":"choice","instructions":"done?","criteria":{"finished":"y"}},"shape":{"type":"choice","instructions":"shape?","criteria":{"hands_on":"h"}}}}
EOF
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/comp-3.json")
expect_code 200 "$http" "a boilerplate-only compaction call reaches the live upstream"
wait_for '\"acknowledged\"' "$BASE_DIR/shadow/shadow.jsonl" "a boilerplate-only compaction request is shadowed"
assert_equals "$topic_skips_before" "$(grep -c '"skipped":"topic"' "$BASE_DIR/shadow/shadow.jsonl" || true)" "a boilerplate-only line does not trigger a topic skip"

# caller-reported redaction skips
cat > "$TMP_ROOT/comp-4.json" <<'EOF'
{"model":"jev-1.14.0","state":{"userConstraints":[],"recent":[],"coverage":{"redacted":true}},"questions":{"done":{"type":"choice","instructions":"d","criteria":{"finished":"y"}},"shape":{"type":"choice","instructions":"s","criteria":{"hands_on":"h"}}}}
EOF
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/comp-4.json")
expect_code 200 "$http" "a redacted-flag compaction call reaches the live upstream"
wait_for '"skipped":"caller-redacted"' "$BASE_DIR/shadow/shadow.jsonl" "a caller-redacted compaction request records a skip"
assert_not_contains "$(grep -F '"skipped":"caller-redacted"' "$BASE_DIR/shadow/shadow.jsonl")" '"request"' "the caller-redacted skip line carries no request content"

# unavailable scan config fails closed for compaction, not for routing
mv "$TMP_ROOT/scan.json" "$TMP_ROOT/scan.json.bak"
compaction_body "$TMP_ROOT/comp-5.json" '' noscan
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/comp-5.json")
expect_code 200 "$http" "a compaction call with no scan config reaches the live upstream"
wait_for '"skipped":"scan-config-unavailable"' "$BASE_DIR/shadow/shadow.jsonl" "a compaction request with no scan config is skipped"
nace_lines_before=$(cat "$NACE_LOG" | wc -l | tr -d ' ')
routing_body "$TMP_ROOT/routing-6.json" six
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/routing-6.json")
expect_code 200 "$http" "a routing call with no scan config reaches the live upstream"
wait_for '\"brief\":\"plain brief six\"' "$BASE_DIR/shadow/shadow.jsonl" "routing still shadows without a scan config"
mv "$TMP_ROOT/scan.json.bak" "$TMP_ROOT/scan.json"
pass "compaction skips on topic hits, caller redaction, and a missing scan config; routing is unaffected"

# --- (c) no key in any record or log ------------------------------------------

leak_targets="$BASE_DIR/shadow/shadow.jsonl $TMP_ROOT/relay-log"
for target in $leak_targets; do
  if grep -F -- "$NACE_KEY" "$target" >/dev/null 2>&1; then
    fail "the shadow key leaked into $target"
  fi
  if grep -F -- 'CALLER-TYPESAFE-KEY' "$target" >/dev/null 2>&1; then
    fail "the caller's TypeSafe key leaked into $target"
  fi
done
pass "no key value appears in any record or relay log"

echo '{"delayMs":5500}' > "$CONTROL_FILE"
routing_body "$TMP_ROOT/shutdown-term.json" shutdown-term
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/shutdown-term.json")
expect_code 200 "$http" "a pending shadow leaves the live reply untouched before stop"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "pending shutdown pair altered live bytes"
kill_relay
shutdown_rec=$(jq -c 'select(.request? | fromjson? | .state.task.brief == "plain brief shutdown-term")' "$BASE_DIR/shadow/shadow.jsonl")
assert_equals 200 "$(jq -r '.shadow.status' <<<"$shutdown_rec")" "stop drains a shadow longer than five seconds through recording"

start_relays || fail "restart for SIGINT failed"
echo '{"delayMs":1500}' > "$CONTROL_FILE"
routing_body "$TMP_ROOT/shutdown-int.json" shutdown-int
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/shutdown-int.json")
expect_code 200 "$http" "a pending shadow leaves the live reply untouched before SIGINT"
kill -INT "$(jq -r '.pid' "$TMP_ROOT/relay.pid")"
wait_for 'plain brief shutdown-int' "$BASE_DIR/shadow/shadow.jsonl" "SIGINT drains the pending pair"
shutdown_rec=$(jq -c 'select(.request? | fromjson? | .state.task.brief == "plain brief shutdown-int")' "$BASE_DIR/shadow/shadow.jsonl")
assert_equals 200 "$(jq -r '.shadow.status' <<<"$shutdown_rec")" "SIGINT retains the settled shadow result"
pass "SIGTERM and SIGINT drain pending pairs before exit"

# --- lifecycle: stop removes the listener -------------------------------------

kill_relay
FM_HOME="$HOME_DIR" "$NODE_BIN" "$RELAY" status >/dev/null 2>&1 && fail "status after stop still reports running"
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  exec 3>&- || true
  fail "the port is still open after stop"
fi
pass "stop terminates the relay and closes the loopback port"

printf '# all fm-de-shadow-relay tests passed\n'
