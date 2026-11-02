#!/usr/bin/env node
// fm-de-shadow-relay.mjs - loopback shadow relay for the Drex Max v1.1 live
// shadow trial beside TypeSafe Jev (data/de-shadow-drexmax/).
//
// Purpose: while a caller's TYPESAFE_BASE or TS_BASE override points at this
// relay, every POST is forwarded to TypeSafe unchanged and TypeSafe's response
// is returned byte for byte. In parallel, the same request body with the
// model id swapped to the shadow model is sent to Nace's System One endpoint
// and one record per call pair is appended under
// the home's private data/de-shadow-drexmax/shadow/. The relay never changes
// the answer, latency or failure behaviour the live caller sees: if this
// relay is down, callers fail exactly as they do when TypeSafe is unreachable
// today, and a slow or failing Nace never delays or alters the live reply.
//
// Usage:
//   fm-de-shadow-relay.mjs start [--port <n>]     daemonize and wait for health
//   fm-de-shadow-relay.mjs start --foreground     run in this process
//   fm-de-shadow-relay.mjs stop                   SIGTERM the daemon, remove pid
//   fm-de-shadow-relay.mjs status                 exit 0 running, 1 not running
//
// Privacy scoping (each layer enforced here, in code):
//   Token gate: shadowing happens only for POST /<token>/v1/systemone where
//     <token> is the contents of the relay-token file. Sessions the main
//     firstmate home launches carry the override; no other home ever receives
//     it, and even a leaked override without the token is proxied only -
//     never sent to Nace, never recorded. The token is read per request, so
//     rotating or deleting the file takes effect immediately; deleting it
//     stops all shadowing. The token segment is stripped before proxying, so
//     TypeSafe sees the plain /v1/systemone path it always did.
//   Compaction content gate: a compaction request (questions carry done or
//     shape) is shadowed only when it passes the topic exclusion scan loaded
//     from topic-scan.json - the same household/money/credentials groups and
//     boilerplate filter the decision-eval used (data/decision-eval/tools/
//     topic_scan.py). Any group hit, a caller-reported coverage.redacted
//     state, or a missing or unreadable scan config skips the shadow: the
//     request never reaches Nace and only a content-free skip line (reason
//     and group names, never request text) is recorded. Routing requests
//     carry only a task brief and are shadowed without the content gate,
//     matching the eval's scope.
//
// Record format: one JSON object per line in shadow.jsonl (mode 600):
//   {ts, use: routing|compaction, request: <raw request body string>,
//    live: {status, body: <raw response string>, usage},
//    shadow: {status, ms, body, usage, error}}
// A skip line carries {ts, use, skipped: <reason>, ...} and no request text.
//
// Key handling: NACE_API_KEY is read once at start from the keys file
//   (default ~/.config/decision-eval/keys.env, the captain-written file) and
//   lives only in this process's memory, sent only as the Authorization
//   header on shadow calls. It is never printed, logged, put on argv, or
//   written to a record. The caller's own TypeSafe Authorization header is
//   forwarded unchanged to TypeSafe and never read.
//
// Configuration (environment, all optional):
//   FM_HOME                    required; data lives under $FM_HOME/data/de-shadow-drexmax/
//   DE_SHADOW_PORT             listen port, default 8931 (always 127.0.0.1 only)
//   DE_SHADOW_TYPESAFE_BASE    live upstream, default https://api.typesafe.ai
//   DE_SHADOW_NACE_BASE        shadow upstream, default https://console.nace.ai
//   DE_SHADOW_NACE_MODEL       shadow model id, default drex-max-v1.1
//   DE_SHADOW_NACE_TIMEOUT_MS  shadow call timeout, default 30000
//   DE_SHADOW_LIVE_TIMEOUT_MS  relay-to-TypeSafe timeout, default 30000
//   DE_SHADOW_KEYS_FILE        keys file, default ~/.config/decision-eval/keys.env
//   DE_SHADOW_SCAN_FILE        topic scan config, default $FM_HOME/data/de-shadow-drexmax/topic-scan.json
//   DE_SHADOW_DIR              records dir, default $FM_HOME/data/de-shadow-drexmax/shadow
//   DE_SHADOW_TOKEN_FILE       token file, default $FM_HOME/data/de-shadow-drexmax/relay-token
//
// Activation (per caller, in the main firstmate home's own launch environment
// only - never a global shell or settings file, which would also activate the
// shadow for the household second mate's sessions):
//   resolver:        TS_BASE=http://127.0.0.1:<port>/<token>
//   Claude Code mod: TYPESAFE_BASE=http://127.0.0.1:<port>/<token>
//   Pi extension:    TYPESAFE_BASE=http://127.0.0.1:<port>/<token>
// Rollback is one line per caller: unset the override; the callers return to
// TypeSafe directly with no other change. Stop the relay with the stop
// command.
import http from "node:http";
import https from "node:https";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";
import { spawn } from "node:child_process";

const SELF_PATH = new URL(import.meta.url).pathname;
const MAX_BODY_BYTES = 10 * 1024 * 1024;
const MAX_RECORDED_BODY = 4 * 1024 * 1024;
const DEFAULT_PORT = 8931;
const pendingPairs = new Set();

function die(message) {
  console.error(`error: ${message}`);
  process.exit(2);
}

function log(line) {
  console.error(`${new Date().toISOString()} ${line}`);
}

function requireHome() {
  const home = process.env.FM_HOME;
  if (!home || home.trim() === "") die("set FM_HOME to the firstmate home this relay records under");
  return home;
}

function resolveConfig() {
  const baseDir = path.join(requireHome(), "data", "de-shadow-drexmax");
  return {
    baseDir,
    shadowDir: process.env.DE_SHADOW_DIR || path.join(baseDir, "shadow"),
    tokenFile: process.env.DE_SHADOW_TOKEN_FILE || path.join(baseDir, "relay-token"),
    pidFile: process.env.DE_SHADOW_PID_FILE || path.join(baseDir, "relay.pid"),
    logFile: process.env.DE_SHADOW_LOG_FILE || path.join(baseDir, "relay.log"),
    keysFile: process.env.DE_SHADOW_KEYS_FILE || path.join(os.homedir(), ".config", "decision-eval", "keys.env"),
    scanFile: process.env.DE_SHADOW_SCAN_FILE || path.join(baseDir, "topic-scan.json"),
    typesafeBase: (process.env.DE_SHADOW_TYPESAFE_BASE || "https://api.typesafe.ai").replace(/\/+$/, ""),
    naceBase: (process.env.DE_SHADOW_NACE_BASE || "https://console.nace.ai").replace(/\/+$/, ""),
    naceModel: process.env.DE_SHADOW_NACE_MODEL || "drex-max-v1.1",
    naceTimeoutMs: Number(process.env.DE_SHADOW_NACE_TIMEOUT_MS || 30000),
    liveTimeoutMs: Number(process.env.DE_SHADOW_LIVE_TIMEOUT_MS || 30000),
    port: Number(process.env.DE_SHADOW_PORT || DEFAULT_PORT),
  };
}

// Keys file format: KEY=VALUE lines, optional `export ` prefix, optional
// matching quotes, # comments. Values never leave this process except as the
// one Authorization header.
export function parseKeysEnv(text) {
  const keys = {};
  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const stripped = line.replace(/^export\s+/, "");
    const eq = stripped.indexOf("=");
    if (eq <= 0) continue;
    let value = stripped.slice(eq + 1).trim();
    if (value.length >= 2 && ((value[0] === '"' && value.endsWith('"')) || (value[0] === "'" && value.endsWith("'")))) {
      value = value.slice(1, -1);
    }
    keys[stripped.slice(0, eq).trim()] = value;
  }
  return keys;
}

function loadNaceKey(keysFile) {
  let text;
  try {
    text = fs.readFileSync(keysFile, "utf8");
  } catch {
    die(`cannot read the keys file ${keysFile} - start is refused so a silent empty shadow week cannot happen`);
  }
  const key = parseKeysEnv(text).NACE_API_KEY;
  if (!key) die(`no NACE_API_KEY in ${keysFile} - start is refused so a silent empty shadow week cannot happen`);
  return key;
}

// The topic exclusion scan config: {groups: {<name>: <regex source>},
// boiler: <regex source>}. Seeded privately from the decision-eval scan.
// Returns null when the file is missing, unreadable, or malformed: the
// compaction gate then fails closed (every compaction request is skipped).
export function loadScanConfig(file) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || typeof parsed.boiler !== "string") return null;
  const groups = {};
  for (const [name, source] of Object.entries(parsed.groups || {})) {
    if (typeof source !== "string" || !source) return null;
    try {
      groups[name] = new RegExp(source, "i");
    } catch {
      return null;
    }
  }
  if (Object.keys(groups).length === 0) return null;
  try {
    return { boiler: new RegExp(parsed.boiler, "i"), groups };
  } catch {
    return null;
  }
}

export function collectStrings(value, into = []) {
  if (typeof value === "string") into.push(value);
  else if (Array.isArray(value)) for (const item of value) collectStrings(item, into);
  else if (value && typeof value === "object") for (const item of Object.values(value)) collectStrings(item, into);
  return into;
}

// Port of the decision-eval topic scan: per line, the boilerplate filter
// drops standard brief lines that name secrets as rules, then each topic
// group regex answers. Returns the group names that hit; never the text.
export function topicGroups(strings, scan) {
  const hits = new Set();
  for (const text of strings) {
    for (const line of text.split(/\r?\n/)) {
      if (scan.boiler.test(line)) continue;
      for (const [name, rx] of Object.entries(scan.groups)) {
        if (rx.test(line)) hits.add(name);
      }
    }
  }
  return [...hits].sort();
}

function classifyUse(questions) {
  if (!questions || typeof questions !== "object") return null;
  if (typeof questions.rule === "object" && questions.rule !== null) return "routing";
  if ((typeof questions.done === "object" && questions.done !== null) ||
      (typeof questions.shape === "object" && questions.shape !== null)) return "compaction";
  return null;
}

function parseUsage(bodyText) {
  try {
    const usage = JSON.parse(bodyText)?.usage;
    return usage && typeof usage === "object" ? usage : null;
  } catch {
    return null;
  }
}

function truncate(text) {
  return text.length > MAX_RECORDED_BODY ? text.slice(0, MAX_RECORDED_BODY) : text;
}

// The shadow gates: classification, then the compaction content exclusions.
// Returns {skipped, use, groups?} or {use, shadowBody}.
export function shadowOutcome(requestBodyText, scan, naceModel) {
  let parsed;
  try {
    parsed = JSON.parse(requestBodyText);
  } catch {
    return { skipped: "unusable-request", use: null };
  }
  if (!parsed || typeof parsed !== "object" || typeof parsed.model !== "string" ||
      !("state" in parsed) || !("questions" in parsed)) {
    return { skipped: "unusable-request", use: null };
  }
  const use = classifyUse(parsed.questions);
  if (use === null) return { skipped: "unknown-use", use: null };
  if (use === "compaction") {
    if (!scan) return { skipped: "scan-config-unavailable", use };
    if (parsed.state && typeof parsed.state === "object" && parsed.state.coverage?.redacted === true) {
      return { skipped: "caller-redacted", use };
    }
    const groups = topicGroups(collectStrings(parsed), scan);
    if (groups.length > 0) return { skipped: "topic", use, groups };
  }
  return { use, shadowBody: JSON.stringify({ ...parsed, model: naceModel }) };
}

async function callNace(shadowBody, naceKey, naceBase, timeoutMs) {
  const started = Date.now();
  return new Promise((resolve) => {
    let settled = false;
    const done = (value) => {
      if (!settled) {
        settled = true;
        resolve(value);
      }
    };
    let upstream;
    try {
      upstream = new URL(naceBase);
    } catch {
      done({ error: "bad shadow upstream url", ms: 0 });
      return;
    }
    const isHttps = upstream.protocol === "https:";
    const mod = isHttps ? https : http;
    const req = mod.request(
      {
        hostname: upstream.hostname,
        port: upstream.port || (isHttps ? 443 : 80),
        path: `${upstream.pathname.replace(/\/+$/, "")}/v1/systemone`,
        method: "POST",
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => done({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8"), ms: Date.now() - started }));
        res.on("error", () => done({ error: "shadow response read failed", ms: Date.now() - started }));
      },
    );
    req.on("timeout", () => {
      req.destroy();
      done({ error: `timeout after ${timeoutMs} ms`, ms: Date.now() - started });
    });
    req.on("error", (err) => done({ error: `network ${err.code || err.message}`, ms: Date.now() - started }));
    req.setTimeout(timeoutMs);
    req.setHeader("Content-Type", "application/json");
    req.setHeader("Authorization", `Bearer ${naceKey}`);
    req.end(shadowBody);
  });
}

// The paired shadow starts alongside the live proxy and records both outcomes
// once settled, independently of the caller's reply.
async function shadowPair(recordFile, requestBodyText, liveResult, cfg, naceKey) {
  // Like the token file, the scan config is re-read per decision so a
  // mid-trial change takes effect immediately; a missing or malformed file
  // fails closed (every compaction request is skipped).
  const outcome = shadowOutcome(requestBodyText, loadScanConfig(cfg.scanFile), cfg.naceModel);
  let line;
  if (outcome.skipped) {
    line = { ts: new Date().toISOString(), use: outcome.use, skipped: outcome.skipped };
    if (outcome.groups) line.groups = outcome.groups;
  } else {
    const [live, shadow] = await Promise.all([
      liveResult,
      callNace(outcome.shadowBody, naceKey, cfg.naceBase, cfg.naceTimeoutMs),
    ]);
    const shadowError = shadow.error ??
      (typeof shadow.status === "number" && (shadow.status < 200 || shadow.status > 299) ? `http ${shadow.status}` : null);
    line = {
      ts: new Date().toISOString(),
      use: outcome.use,
      request: truncate(requestBodyText),
      live: live.error ? { status: null, error: live.error } :
        { status: live.status, ms: live.ms, body: truncate(live.bodyText), usage: parseUsage(live.bodyText) },
      shadow: {
        status: shadow.status ?? null,
        ms: shadow.ms ?? null,
        body: typeof shadow.body === "string" ? truncate(shadow.body) : null,
        usage: typeof shadow.body === "string" ? parseUsage(shadow.body) : null,
        error: shadowError,
      },
    };
  }
  try {
    fs.appendFileSync(recordFile, `${JSON.stringify(line)}\n`, { mode: 0o600 });
  } catch (err) {
    log(`record append failed: ${err.code || err.message}`);
    return;
  }
  if (outcome.skipped && outcome.skipped !== "unusable-request" && outcome.skipped !== "unknown-use") {
    log(`skipped reason=${outcome.skipped}${outcome.groups ? ` groups=${outcome.groups.join("+")}` : ""}`);
  }
}

function readToken(tokenFile) {
  try {
    const token = fs.readFileSync(tokenFile, "utf8").trim();
    return /^[A-Za-z0-9_-]{16,128}$/.test(token) ? token : null;
  } catch {
    return null;
  }
}

// The live proxy: forwards the request to TypeSafe with the caller's headers
// unchanged (Authorization included) and writes TypeSafe's response body
// back byte for byte. Calls onLiveDone only after the caller's response is
// fully sent, so the shadow can never sit on the caller's critical path.
function proxyToTypeSafe(req, res, body, cfg, onLiveDone = () => {}) {
  const liveStarted = Date.now();
  // A timeout destroys the socket, which then also fires the error handler:
  // the live outcome settles exactly once so the shadow pair is recorded once.
  let liveSettled = false;
  const liveDone = (value) => {
    if (!liveSettled) {
      liveSettled = true;
      onLiveDone?.(value);
    }
  };
  let upstream;
  try {
    upstream = new URL(cfg.typesafeBase);
  } catch {
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end('{"error":"relay misconfigured: bad live upstream"}');
    liveDone({ status: null, error: "bad live upstream url" });
    return;
  }
  const isHttps = upstream.protocol === "https:";
  const mod = isHttps ? https : http;
  const headers = { ...req.headers };
  // Hop-by-hop and recomputed headers only. The caller's Authorization header
  // is forwarded unchanged; accept-encoding is dropped so the caller receives
  // the uncompressed bytes TypeSafe itself produced.
  delete headers.host;
  delete headers.connection;
  delete headers["content-length"];
  delete headers["accept-encoding"];
  headers.host = upstream.host;
  const upstreamReq = mod.request(
    {
      hostname: upstream.hostname,
      port: upstream.port || (isHttps ? 443 : 80),
      path: req.url,
      method: req.method,
      headers,
    },
    (upstreamRes) => {
      const chunks = [];
      upstreamRes.on("data", (chunk) => chunks.push(chunk));
      upstreamRes.on("end", () => {
        const bodyBytes = Buffer.concat(chunks);
        res.writeHead(upstreamRes.statusCode || 502, {
          "content-type": upstreamRes.headers["content-type"] || "application/json",
          "content-length": bodyBytes.length,
        });
        res.end(bodyBytes);
        liveDone({ status: upstreamRes.statusCode || 502, bodyText: bodyBytes.toString("utf8"), ms: Date.now() - liveStarted });
      });
      upstreamRes.on("error", () => {
        if (!res.headersSent) {
          res.writeHead(502, { "Content-Type": "application/json" });
          res.end('{"error":"live upstream read failed"}');
        } else {
          res.destroy();
        }
        liveDone({ status: null, error: "live upstream read failed" });
      });
    },
  );
  upstreamReq.on("timeout", () => {
    upstreamReq.destroy();
    if (!res.headersSent) {
      res.writeHead(504, { "Content-Type": "application/json" });
      res.end('{"error":"live upstream timeout"}');
    }
    liveDone({ status: null, error: "live upstream timeout" });
  });
  upstreamReq.on("error", () => {
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end('{"error":"live upstream unreachable"}');
    }
    liveDone({ status: null, error: "live upstream unreachable" });
  });
  upstreamReq.setTimeout(cfg.liveTimeoutMs);
  upstreamReq.end(body);
}

function runServer(cfg, naceKey) {
  const recordFile = path.join(cfg.shadowDir, "shadow.jsonl");
  fs.mkdirSync(cfg.shadowDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(cfg.shadowDir, 0o700);
  if (!fs.existsSync(recordFile)) fs.writeFileSync(recordFile, "", { mode: 0o600 });
  fs.chmodSync(recordFile, 0o600);

  const server = http.createServer((req, res) => {
    const route = (req.url || "").split("?")[0];
    if (req.method === "GET" && route === "/health") {
      res.writeHead(200, { "Content-Type": "text/plain", "x-relay-pid": String(process.pid) });
      res.end("ok");
      return;
    }
    if (req.method !== "POST") {
      res.writeHead(405, { "Content-Type": "application/json" });
      res.end('{"error":"POST only"}');
      return;
    }
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        tooLarge = true;
        if (!res.headersSent) {
          res.writeHead(413, { "Content-Type": "application/json" });
          res.end('{"error":"request too large"}');
        }
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (tooLarge) return;
      const body = Buffer.concat(chunks);
      const token = readToken(cfg.tokenFile);
      const shadowRoute = token !== null && route === `/${token}/v1/systemone`;
      if (/^\/[^/]+\/v1\/systemone$/.test(route)) {
        req.url = `/v1/systemone${req.url.slice(route.length)}`;
      }
      let onLiveDone;
      if (shadowRoute) {
        const liveResult = new Promise((resolve) => { onLiveDone = resolve; });
        const pair = shadowPair(recordFile, body.toString("utf8"), liveResult, cfg, naceKey)
          .catch((err) => log(`pair failed: ${err.code || err.message}`));
        pendingPairs.add(pair);
        pair.finally(() => pendingPairs.delete(pair));
      }
      proxyToTypeSafe(req, res, body, cfg, onLiveDone);
    });
    req.on("error", () => {});
  });
  server.on("error", (err) => die(`cannot listen on 127.0.0.1:${cfg.port}: ${err.code || err.message}`));
  // Loopback only, always: the binding is not configurable.
  server.listen(cfg.port, "127.0.0.1", () => {
    log(`listening 127.0.0.1:${cfg.port}; records ${recordFile}`);
  });
  let stopping = false;
  const shutdown = () => {
    if (stopping) return;
    stopping = true;
    log("stopping");
    const drainMs = Math.min(cfg.naceTimeoutMs, 10000);
    const closed = new Promise((resolve) => server.close(resolve));
    Promise.race([
      closed.then(() => Promise.allSettled([...pendingPairs])),
      new Promise((resolve) => setTimeout(resolve, drainMs)),
    ]).then(() => process.exit(0));
    setTimeout(() => process.exit(0), drainMs + 250).unref();
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

function waitHealthy(port, deadlineMs, expectedPid) {
  const deadline = Date.now() + deadlineMs;
  return new Promise((resolve) => {
    const poll = () => {
      const req = http.get({ host: "127.0.0.1", port, path: "/health", timeout: 500 }, (res) => {
        res.resume();
        resolve(res.statusCode === 200 &&
          (expectedPid === undefined || res.headers["x-relay-pid"] === String(expectedPid)));
      });
      req.on("error", () => retry());
      req.on("timeout", () => {
        req.destroy();
      });
    };
    const retry = () => {
      if (Date.now() > deadline) resolve(false);
      else setTimeout(poll, 100);
    };
    poll();
  });
}

// The pid file is one JSON object {pid, port} so stop and status address the
// same port the daemon was started on, not a later default.
function readRuntime(pidFile) {
  try {
    const runtime = JSON.parse(fs.readFileSync(pidFile, "utf8"));
    if (Number.isInteger(runtime?.pid) && runtime.pid > 0 &&
        Number.isInteger(runtime?.port) && runtime.port > 0) return runtime;
    return null;
  } catch {
    return null;
  }
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function cmdStart() {
  const cfg = resolveConfig();
  const flags = process.argv.slice(3);
  for (let i = 0; i < flags.length; i++) {
    if (flags[i] === "--port") {
      i++;
      cfg.port = Number(flags[i]);
      if (!Number.isInteger(cfg.port) || cfg.port < 1 || cfg.port > 65535) die("--port needs a port number between 1 and 65535");
    } else if (flags[i] !== "--foreground") {
      die(`unknown option ${flags[i]}`);
    }
  }
  if (!flags.includes("--foreground") && await waitHealthy(cfg.port, 300)) {
    console.log(`relay already-running 127.0.0.1:${cfg.port}`);
    return;
  }
  fs.mkdirSync(cfg.baseDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(cfg.baseDir, 0o700);
  if (!fs.existsSync(cfg.tokenFile)) {
    fs.writeFileSync(cfg.tokenFile, `${crypto.randomBytes(32).toString("hex")}\n`, { mode: 0o600 });
  }
  fs.chmodSync(cfg.tokenFile, 0o600);
  // Refuse to start without the shadow key: a relay that runs without it
  // would spend a week answering health checks while recording nothing.
  const naceKey = loadNaceKey(cfg.keysFile);

  if (process.argv.includes("--foreground")) {
    runServer(cfg, naceKey);
    return;
  }
  const logFd = fs.openSync(cfg.logFile, "a", 0o600);
  const child = spawn(process.execPath, [SELF_PATH, "start", "--foreground", "--port", String(cfg.port)], {
    detached: true,
    stdio: ["ignore", logFd, logFd],
    env: process.env,
  });
  fs.closeSync(logFd);
  const healthy = await waitHealthy(cfg.port, 5000, child.pid);
  if (!healthy) {
    try {
      child.kill("SIGTERM");
    } catch {}
    die(`relay did not become healthy on 127.0.0.1:${cfg.port} - see ${cfg.logFile}`);
  }
  fs.writeFileSync(cfg.pidFile, `${JSON.stringify({ pid: child.pid, port: cfg.port })}\n`, { mode: 0o600 });
  console.log(`relay listening 127.0.0.1:${cfg.port}`);
  console.log(`records: ${path.join(cfg.shadowDir, "shadow.jsonl")}`);
  console.log(`token file: ${cfg.tokenFile}`);
  console.log(`stop: ${SELF_PATH} stop`);
  child.unref();
}

function cmdStop() {
  const pidFile = resolveConfig().pidFile;
  const runtime = readRuntime(pidFile);
  const pid = runtime?.pid ?? null;
  if (!pid) {
    console.log("relay not running (no usable pid file)");
    return;
  }
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    fs.rmSync(pidFile, { force: true });
    console.log("relay not running (stale pid)");
    return;
  }
  const deadline = Date.now() + 11000;
  const poll = () => {
    if (!pidAlive(pid)) {
      fs.rmSync(pidFile, { force: true });
      console.log("relay stopped");
      return;
    }
    if (Date.now() > deadline) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {}
      fs.rmSync(pidFile, { force: true });
      console.log("relay stopped (forced)");
      return;
    }
    setTimeout(poll, 100);
  };
  poll();
}

function cmdStatus() {
  const cfg = resolveConfig();
  const runtime = readRuntime(cfg.pidFile);
  const port = runtime?.port ?? cfg.port;
  const pid = runtime?.pid ?? null;
  if (!pid || !pidAlive(pid)) {
    console.log("status: not running");
    process.exit(1);
  }
  const req = http.get({ host: "127.0.0.1", port, path: "/health", timeout: 1000 }, (res) => {
    res.resume();
    if (res.statusCode === 200) {
      console.log(`status: running pid=${pid} 127.0.0.1:${port}`);
      process.exit(0);
    } else {
      console.log(`status: unhealthy pid=${pid} http ${res.statusCode}`);
      process.exit(1);
    }
  });
  req.on("error", () => {
    console.log(`status: process alive pid=${pid} but not answering on 127.0.0.1:${port}`);
    process.exit(1);
  });
  req.on("timeout", () => {
    req.destroy();
    console.log(`status: process alive pid=${pid} but not answering on 127.0.0.1:${port}`);
    process.exit(1);
  });
}

async function main() {
  const command = process.argv[2];
  if (command === "start") await cmdStart();
  else if (command === "stop") cmdStop();
  else if (command === "status") cmdStatus();
  else die("usage: fm-de-shadow-relay.mjs start [--port <n>] [--foreground] | stop | status");
}

main();
