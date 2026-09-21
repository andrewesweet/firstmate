#!/usr/bin/env bash
# Live probe: the Pi supervision-branch extension against the REAL installed
# pi-coding-agent SDK and its REAL ModelRuntime (local models.json, fetch
# intercepted in-process so no request leaves the machine). Five scenarios,
# each in a fresh home and process, driven through the real watcher tool and
# the real wake path. Records every provider request's model, and the
# durable classification record, into the evidence directory.
set -u
ROOT=${ROOT:?}
EVIDENCE=${EVIDENCE:?}
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent"
export NODE_NO_WARNINGS=1
TMP_ROOT=$(mktemp -d /tmp/fm-pi-classifier-live.XXXXXX)
trap 'pkill -f "$TMP_ROOT/" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT
repo="$TMP_ROOT/repo"
mkdir -p "$repo/.pi/extensions/lib" "$repo/lib" "$repo/node_modules/@earendil-works" "$repo/bin"
for f in fm-branch-supervision.ts fm-primary-pi-watch.ts; do cp "$ROOT/.pi/extensions/$f" "$repo/.pi/extensions/$f"; done
for f in fm-branch-dispatch fm-native-contract fm-async-exec fm-branch-model-picker fm-calm-visibility fm-operational-input; do
  cp "$ROOT/.pi/extensions/lib/$f.ts" "$repo/.pi/extensions/lib/$f.ts"; done
for f in fm-branch-classifier fm-branch-eligibility fm-branch-shadow fm-branch-report-sequence fm-branch-provider-latch; do
  cp "$ROOT/lib/$f.ts" "$repo/lib/$f.ts"; done
cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
cat > "$repo/bin/fm-watch-arm.sh" <<'W'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_LIVE_WATCH_LOG:?}"; exit 0; fi
printf 'arm pid=%s\n' "$$" >> "${FM_LIVE_WATCH_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=live-sdk-generation\n' "$$"
trap 'exit 0' TERM INT
while :; do
  if [ -e "$FM_LIVE_WATCH_TRIGGER" ]; then reason=$(cat "$FM_LIVE_WATCH_TRIGGER"); rm -f "$FM_LIVE_WATCH_TRIGGER"; printf '%s\n' "$reason"; exit 0; fi
  sleep 0.02
done
W
chmod +x "$repo/bin/"*.sh
ln -s "$PI_PACKAGE_DIR" "$repo/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$repo/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$repo/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$repo/node_modules/typebox"

# run_scenario <name> <classifier-model|-> <pin|-> <main-model-id> <expect-classifier-model-id> <expect-record-model> <expect-verdict> <classifier-provider-mode>
run_scenario() {
  local name=$1 cfg=$2 pin=$3 mainid=$4 expectid=$5 expectrec=$6 expectverdict=$7 mode=$8
  local home="$TMP_ROOT/$name-home" agentdir="$TMP_ROOT/$name-agent"
  mkdir -p "$home/state" "$home/config" "$agentdir"
  cat > "$agentdir/models.json" <<'JSON'
{ "providers": { "fm-live": { "baseUrl": "https://fm-live.invalid/v1", "api": "openai-completions", "apiKey": "fm-live-placeholder",
  "models": [ { "id": "fm-main", "name": "main", "contextWindow": 8192, "maxTokens": 512 },
              { "id": "fm-pinned", "name": "pinned", "contextWindow": 8192, "maxTokens": 512 },
              { "id": "fm-explicit", "name": "explicit", "contextWindow": 8192, "maxTokens": 512 } ] } } }
JSON
  [ "$cfg" != - ] && printf '%s\n' "$cfg" > "$home/config/classifier-model"
  [ "$pin" != - ] && printf '%s\n' "$pin" > "$home/config/supervision-branch-model"
  BRANCH_PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" WATCH_PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
    FM_HOME="$home" FM_REAL_ROOT="$ROOT" FM_WATCH_ROOT="$repo" \
    FM_LIVE_WATCH_LOG="$TMP_ROOT/$name.watch.log" FM_LIVE_WATCH_TRIGGER="$TMP_ROOT/$name.trigger" \
    PI_CODING_AGENT_DIR="$agentdir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
    SCN="$name" MAIN_ID="$mainid" EXPECT_ID="$expectid" EXPECT_REC="$expectrec" EXPECT_VERDICT="$expectverdict" MODE="$mode" \
    node --input-type=module > "$TMP_ROOT/$name.out" 2>&1 <<'EOF'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
const home = resolve(process.env.FM_HOME);
const project = `${home}/projects/probe`;
mkdirSync(project, { recursive: true });
writeFileSync(`${home}/state/probe.meta`, `project=${project}\nwindow=fm-probe\n`);
writeFileSync(`${home}/state/.wake-queue`, `1\t1\tsignal\tprobe.status\tsignal: ${process.env.SCN} probe\n`);
const requests = [];
globalThis.fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (!url.startsWith("https://fm-live.invalid/")) throw new Error(`unexpected network request: ${url}`);
  const body = JSON.parse(String(init?.body ?? "{}"));
  const sys = (body.messages ?? []).find((m) => m.role === "system" || m.role === "developer");
  const sysText = typeof sys?.content === "string" ? sys.content : JSON.stringify(sys?.content ?? "");
  const isClassifier = sysText.startsWith("You are the wake classifier");
  requests.push({ model: body.model, kind: isClassifier ? "classifier" : "branch" });
  if (isClassifier && process.env.MODE === "routine") {
    const chunk = (delta, finish) => `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: body.model,
      choices: [{ index: 0, delta, finish_reason: finish }], ...(finish ? { usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } } : {}) })}\n\n`;
    const text = chunk({ role: "assistant", content: '{"verdict":"routine","reason":"probe"}' }, null) + chunk({}, "stop") + "data: [DONE]\n\n";
    return new Response(text, { status: 200, headers: { "content-type": "text/event-stream" } });
  }
  return new Response(JSON.stringify({ error: { message: "Monthly usage limit reached", type: "insufficient_quota" } }),
    { status: 429, headers: { "content-type": "application/json" } });
};
const busHandlers = new Map(); const offers = [];
const bus = { on(c, h) { busHandlers.set(c, [...(busHandlers.get(c) ?? []), h]); return () => {}; },
  emit(c, d) { for (const h of busHandlers.get(c) ?? []) h(d); if (c === "fm-branch-supervision:dispatch") offers.push(d); } };
const piHandlers = new Map(); const mainUserMessages = []; let watcherTool = null; let sessionCtx = {};
const pi = { events: bus, on(e, h) { piHandlers.set(e, [...(piHandlers.get(e) ?? []), h]); },
  registerTool(t) { if (t.name === "fm_watch_arm_pi") watcherTool = t; },
  registerCommand() {}, registerMessageRenderer() {}, sendMessage() {},
  async sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
    for (const h of piHandlers.get("before_agent_start") ?? []) await h({ prompt: content }, sessionCtx);
    for (const h of piHandlers.get("message_start") ?? []) await h({ message: { role: "user", content: [{ type: "text", text: content }] } }, sessionCtx);
  },
  getThinkingLevel() { return "off"; } };
process.env.FM_ROOT_OVERRIDE = process.env.FM_REAL_ROOT;
(await import(pathToFileURL(process.env.BRANCH_PLUGIN).href)).default(pi);
process.env.FM_ROOT_OVERRIDE = process.env.FM_WATCH_ROOT;
(await import(pathToFileURL(process.env.WATCH_PLUGIN).href)).default(pi);
sessionCtx = { model: { provider: "fm-live", id: process.env.MAIN_ID },
  sessionManager: { getSessionFile: () => `${home}/main.jsonl`, getEntries: () => [] } };
const waitFor = async (p, label) => { for (let i = 0; i < 600; i += 1) { if (p()) return; await new Promise((r) => setTimeout(r, 50)); } throw new Error(`timeout waiting for ${label}`); };
for (const h of piHandlers.get("session_start") ?? []) await h({ type: "session_start", reason: "startup" }, sessionCtx);
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
if (!watcherTool) throw new Error("watcher tool not registered");
const armed = await watcherTool.execute("arm", {}, undefined, undefined, {});
if (!armed.details?.ok) throw new Error(`watcher did not arm: ${JSON.stringify(armed.details)}`);
await waitFor(() => existsSync(process.env.FM_LIVE_WATCH_LOG), "watcher arm");
writeFileSync(process.env.FM_LIVE_WATCH_TRIGGER, `signal: ${process.env.SCN} probe\n`);
await waitFor(() => mainUserMessages.length === 1, "watcher-owned main delivery");
if (offers.length !== 1 || !offers[0].accepted) throw new Error(`offer not accepted: ${JSON.stringify(offers)}`);
const settled = await offers[0].settlement.then(() => "resolved", (e) => `rejected: ${e.message}`);
const classFile = `${home}/state/branch-mod-classifications.jsonl`;
await waitFor(() => existsSync(classFile), "classification record");
const records = readFileSync(classFile, "utf8").trim().split("\n").map((l) => JSON.parse(l));
const classifierRequests = requests.filter((r) => r.kind === "classifier");
const report = { scenario: process.env.SCN, mainModel: `fm-live/${process.env.MAIN_ID}`,
  configuredClassifierModel: existsSync(`${home}/config/classifier-model`) ? readFileSync(`${home}/config/classifier-model`, "utf8").trim() : null,
  pin: existsSync(`${home}/config/supervision-branch-model`) ? readFileSync(`${home}/config/supervision-branch-model`, "utf8").trim() : null,
  providerRequests: requests, settlement: settled, mainDelivery: mainUserMessages[0].content.split("\n")[0],
  record: { model: records[0].model, verdict: records[0].verdict, answer: records[0].answer } };
console.log(JSON.stringify(report, null, 2));
const failures = [];
if (process.env.EXPECT_ID === "-") { if (classifierRequests.length !== 0) failures.push(`expected no classifier request, got ${JSON.stringify(classifierRequests)}`); }
else if (classifierRequests.length !== 1 || classifierRequests[0].model !== process.env.EXPECT_ID) failures.push(`expected exactly one classifier request on ${process.env.EXPECT_ID}, got ${JSON.stringify(classifierRequests)}`);
if (records.length !== 1 || records[0].model !== process.env.EXPECT_REC) failures.push(`expected record model ${process.env.EXPECT_REC}, got ${JSON.stringify(records)}`);
if (records[0].verdict !== process.env.EXPECT_VERDICT) failures.push(`expected verdict ${process.env.EXPECT_VERDICT}, got ${records[0].verdict}`);
if (failures.length) { console.log("FAIL: " + failures.join(" | ")); process.exit(1); }
console.log("SCENARIO_OK");
process.exit(0);
EOF
  local status=$?
  cp "$TMP_ROOT/$name.out" "$EVIDENCE/pi-live-$name.log"
  if [ "$status" -eq 0 ]; then echo "ok - $name"; else echo "not ok - $name"; tail -5 "$TMP_ROOT/$name.out"; fi
  return "$status"
}
rc=0
run_scenario unconfigured-follows-main - - fm-main fm-main fm-live/fm-main routine routine || rc=1
run_scenario unconfigured-follows-pin - fm-live/fm-pinned fm-main fm-pinned fm-live/fm-pinned routine routine || rc=1
run_scenario explicit-config-wins fm-live/fm-explicit fm-live/fm-pinned fm-main fm-explicit fm-live/fm-explicit routine routine || rc=1
run_scenario unresolvable-config-falls-back-once ghost/model fm-live/fm-pinned fm-main fm-pinned fm-live/fm-pinned routine routine || rc=1
run_scenario quota-failure-no-fallback fm-live/fm-explicit fm-live/fm-pinned fm-main fm-explicit fm-live/fm-explicit uncertain quota || rc=1
exit $rc
