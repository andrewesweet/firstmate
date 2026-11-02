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

const [safePort, safeLog, nacePort, naceLog, bodyFile, controlFile] = process.argv.slice(2);
const canned = fs.readFileSync(bodyFile);

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

serve(safePort, safeLog, (req, res) => {
  res.writeHead(200, { "content-type": "application/json", "x-fake": "live" });
  res.end(canned);
});

serve(nacePort, naceLog, (req, res) => {
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
echo '{}' > "$CONTROL_FILE"

# The canned live response: unicode-free but with irregular interior spacing,
# trailing whitespace, and no trailing newline, so a byte-for-byte assertion
# catches any normalisation - while staying valid JSON so usage parses.
printf '{ "model": "jev-1.14.0", "answers": { "rule": { "type": "choice", "choice": "rule_2", "confidence": 0.71,\n    "probabilities": { "rule_1": 0.05, "rule_2": 0.71, "default": 0.24 } } },\n  "usage": { "input_tokens": 812, "output_tokens": 60 } }\x20\x20' > "$TMP_ROOT/canned-live.json"

NODE_BIN=$(command -v node)
node "$TMP_ROOT/bin/fake-upstream.mjs" "$SAFE_PORT" "$SAFE_LOG" "$NACE_PORT" "$NACE_LOG" "$TMP_ROOT/canned-live.json" "$CONTROL_FILE" &
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
trap 'kill_relay; kill "$FAKE_PID" 2>/dev/null || true' EXIT

# wait_for <pattern> <file> <msg>: poll up to 10s for a fixed-string record.
wait_for() {
  local pattern=$1 file=$2 msg=$3 i
  for i in $(seq 1 100); do
    [ -f "$file" ] && grep -F -- "$pattern" "$file" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "$msg (pattern not found within 10s in $file)"
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

# --- (b) slow or failing Nace never delays or alters the caller --------------

# slow Nace: the caller still gets the identical bytes quickly
echo '{"delayMs":1500}' > "$CONTROL_FILE"
routing_body "$TMP_ROOT/routing-2.json" two
t0=$(date +%s%N)
http=$(post "/$TOKEN/v1/systemone" "$TMP_ROOT/routing-2.json")
t1=$(date +%s%N)
elapsed_ms=$(( (t1 - t0) / 1000000 ))
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

# --- (d) only token-bearing requests are shadowed -----------------------------

lines_before=$(records | wc -l | tr -d ' ')
nace_lines_before=$(cat "$NACE_LOG" | wc -l | tr -d ' ')
routing_body "$TMP_ROOT/routing-5.json" five
http=$(post "/v1/systemone" "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a token-less call still reaches the live upstream"
cmp -s "$TMP_ROOT/reply.bin" "$TMP_ROOT/canned-live.json" || fail "a token-less call is not proxied byte for byte"
http=$(post "/wrongtoken12345678901234567890/v1/systemone" "$TMP_ROOT/routing-5.json")
expect_code 200 "$http" "a wrong-token call still reaches the live upstream"
sleep 0.5
assert_equals "$lines_before" "$(records | wc -l | tr -d ' ')" "token-less and wrong-token calls record nothing"
assert_equals "$nace_lines_before" "$(cat "$NACE_LOG" | wc -l | tr -d ' ')" "token-less and wrong-token calls never reach Nace"
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

# --- lifecycle: stop removes the listener -------------------------------------

kill_relay
FM_HOME="$HOME_DIR" "$NODE_BIN" "$RELAY" status >/dev/null 2>&1 && fail "status after stop still reports running"
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  exec 3>&- || true
  fail "the port is still open after stop"
fi
pass "stop terminates the relay and closes the loopback port"

printf '# all fm-de-shadow-relay tests passed\n'
