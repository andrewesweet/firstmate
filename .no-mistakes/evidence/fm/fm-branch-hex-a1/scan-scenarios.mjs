import { mkdirSync, writeFileSync, rmSync, chmodSync, appendFileSync, utimesSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import assert from "node:assert/strict";
const root = process.env.FM_ROOT;
const lib = await import(pathToFileURL(`${root}/lib/fm-branch-eligibility.ts`).href);
const bashFold = (dir, t, env = {}) => execFileSync("bash", ["-c", '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2/$3.status"', "_", root, dir, t], { env: { ...process.env, ...env }, encoding: "utf8" });
const mk = (name, files) => { const d = `/tmp/fmelig/sc/${name}`; rmSync(d, { recursive: true, force: true }); mkdirSync(d, { recursive: true }); for (const [f, c] of Object.entries(files)) writeFileSync(`${d}/${f}`, c); return d; };
const S = (s) => JSON.stringify({ status: s.status, eligible: s.eligible, corrupted: s.corrupted, seqs: s.eligibleSeqs, wakeKey: s.eligibleWakeKey, tasks: s.eligibleTasks, nd: s.needsDecisionTasks, all: s.allSeqs, check: s.checkSeqs, hb: s.heartbeatSeqs, projects: s.projects });
const log = (label, v) => console.log(`${label}: ${typeof v === "string" ? v : JSON.stringify(v)}`);

// 1. unreadable status log: bash empty fold; lib empty fold + row eligible
{
  const d = mk("unreadable", { "t.status": "needs-decision [key=a]: pick\n", "t.meta": "kind=ship\nproject=demo\n", ".wake-queue": "1\t1\tstale\tt\tstale: x\n" });
  chmodSync(`${d}/t.status`, 0o000);
  const b = bashFold(d, "t"); const l = lib.foldStatusLog(d, "t"); const s = lib.scanStateDirectory(d);
  log("unreadable bash fold", b); log("unreadable lib fold", l); log("unreadable scan", S(s));
  assert.equal(b, ""); assert.equal(l, ""); assert.equal(s.status, "safe"); assert.deepEqual(s.eligibleSeqs, ["1"]);
  chmodSync(`${d}/t.status`, 0o644);
}
// 2. torn seq row -> unsafe/corrupted; unknown row kind -> unsafe/corrupted
{
  const d = mk("torn-seq", { "t.status": "working: x\n", "t.meta": "kind=ship\nproject=demo\n", ".wake-queue": "1\tx\tsignal\tt.status\tsignal: working\n" });
  const s = lib.scanStateDirectory(d); log("torn-seq scan", S(s)); assert.equal(s.corrupted, true); assert.equal(s.status, "unsafe");
  const d2 = mk("unknown-kind", { "t.status": "working: x\n", "t.meta": "kind=ship\nproject=demo\n", ".wake-queue": "1\t1\tbogus\tt.status\tx\n" });
  const s2 = lib.scanStateDirectory(d2); log("unknown-kind scan", S(s2)); assert.equal(s2.corrupted, true);
  const d3 = mk("short-row", { "t.status": "working: x\n", "t.meta": "kind=ship\nproject=demo\n", ".wake-queue": "1\t1\tsignal\tt.status\n" });
  const s3 = lib.scanStateDirectory(d3); log("short-row scan", S(s3)); assert.equal(s3.corrupted, true);
}
// 3. unresolvable signal row (no meta / meta without project) -> unsafe
{
  const d = mk("no-meta", { "t.status": "working: x\n", ".wake-queue": "1\t1\tsignal\tt.status\tsignal: working\n" });
  const s = lib.scanStateDirectory(d); log("no-meta scan", S(s)); assert.equal(s.corrupted, true);
}
// 4. check/heartbeat rows: excluded (not veto) attended; claimed afk/heartbeat; wake-key derivation
{
  const d = mk("mixed", { "t.status": "working: x\n", "t.meta": "kind=ship\nproject=demo\nwindow=fm-t-win\n", ".wake-queue": "10\t1\tcheck\tcheck\tcheck: x\n11\t2\theartbeat\thb\thb: x\n12\t3\tsignal\tt.status\tsignal: working\n13\t4\tsignal\tt.turn-ended\tneeds-decision: pick\n14\t5\tstale\tfm-fm-t-win\tstale: x\n" });
  const a = lib.scanStateDirectory(d); log("mixed attended", S(a));
  assert.deepEqual(a.eligibleSeqs, ["3", "5"]); assert.equal(a.eligibleWakeKey, "12:3,14:5"); assert.deepEqual(a.needsDecisionTasks, ["t"]); assert.deepEqual(a.allSeqs, ["1","2","3","4","5"]);
  const h = lib.scanStateDirectory(d, { heartbeat: true }); log("mixed heartbeat", S(h)); assert.deepEqual(h.heartbeatSeqs, ["2"]); assert.deepEqual(h.checkSeqs, []);
  const f = lib.scanStateDirectory(d, { afk: true }); log("mixed afk", S(f));
  assert.deepEqual(f.eligibleSeqs, ["1","2","3","4","5"]); assert.equal(f.eligibleWakeKey, "10:1,11:2,12:3,13:4,14:5"); assert.deepEqual(f.checkSeqs, ["1"]);
}
// 5. empty queue -> empty scope even when metas broken; missing queue -> unsafe
{
  const d = mk("empty-q", { ".wake-queue": "" }); const s = lib.scanStateDirectory(d); log("empty queue", S(s)); assert.equal(s.status, "empty"); assert.equal(s.corrupted, false);
  const d2 = mk("no-q", {}); const s2 = lib.scanStateDirectory(d2); log("missing queue", S(s2)); assert.equal(s2.corrupted, true);
}
// 6. file-version cache: verdict follows an edit to the log within one process; stale cache never survives a content change
{
  const d = mk("cache", { "t.status": "working: x\n", "t.meta": "kind=ship\nproject=demo\n", ".wake-queue": "1\t1\tstale\tt\tstale: x\n" });
  const cache = new Map();
  const s1 = lib.scanStateDirectory(d, { cache }); log("cache scan1", S(s1)); assert.equal(s1.eligible, true);
  appendFileSync(`${d}/t.status`, "needs-decision [key=a]: pick\n");
  const s2 = lib.scanStateDirectory(d, { cache }); log("cache scan2 after append", S(s2)); assert.deepEqual(s2.needsDecisionTasks, ["t"]); assert.equal(s2.eligible, false);
  // same-size, same-mtime rewrite: version includes ctime/ino so replace-by-rename invalidates
  writeFileSync(`${d}/t.status.new`, "resolved [key=a]: done picking\n"); // content differs anyway; test rename path
  execFileSync("mv", [`${d}/t.status.new`, `${d}/t.status`]);
  const s3 = lib.scanStateDirectory(d, { cache }); log("cache scan3 after rename", S(s3)); assert.equal(s3.eligible, true);
  // removing the log between scans drops the cache entry
  rmSync(`${d}/t.status`); const s4 = lib.scanStateDirectory(d, { cache }); log("cache scan4 log removed", S(s4)); assert.equal(s4.eligible, true); assert.equal(cache.has("t"), false);
}
// 7. paused verb in cache config: env change flips the verdict with a warm cache; bash agrees on each side
{
  const d = mk("paused", { "t.status": "captain-held: waiting\nhold-on: x\n", "t.meta": "kind=ship\nproject=demo\n", ".wake-queue": "1\t1\tstale\tt\tstale: x\n" });
  const held = (env) => execFileSync("bash", ["-c", '. "$1/bin/fm-classify-lib.sh"; l=$(last_status_line "$2/t.status"); status_is_captain_held "$l" && echo held || echo free', "_", root, d], { env: { ...process.env, ...env }, encoding: "utf8" }).trim();
  const cache = new Map();
  delete process.env.FM_CLASSIFY_PAUSED_VERB;
  const s1 = lib.scanStateDirectory(d, { cache }); log("paused default lib", S(s1)); log("paused default bash", held({}));
  assert.deepEqual(s1.needsDecisionTasks, ["t"]); assert.equal(held({}), "held");
  process.env.FM_CLASSIFY_PAUSED_VERB = "hold-on";
  const s2 = lib.scanStateDirectory(d, { cache }); log("paused=hold-on lib (warm cache)", S(s2)); log("paused=hold-on bash", held({ FM_CLASSIFY_PAUSED_VERB: "hold-on" }));
  assert.deepEqual(s2.needsDecisionTasks, []); assert.equal(s2.eligible, true); assert.equal(held({ FM_CLASSIFY_PAUSED_VERB: "hold-on" }), "free");
  delete process.env.FM_CLASSIFY_PAUSED_VERB;
}
// 8. reserved-prefix override reaches both folds
{
  const d = mk("reserved", { "t.status": "needs-decision [key=dep-1]: pick\nneeds-decision [key=dep-2]: dep-: spoken\n", "t.meta": "kind=ship\nproject=demo\n" });
  const env = { FM_CLASSIFY_RESERVED_KEY_PREFIXES: "pending-reply- dep-" };
  const b = bashFold(d, "t", env); process.env.FM_CLASSIFY_RESERVED_KEY_PREFIXES = env.FM_CLASSIFY_RESERVED_KEY_PREFIXES; const l = lib.foldStatusLog(d, "t"); delete process.env.FM_CLASSIFY_RESERVED_KEY_PREFIXES;
  log("reserved-override bash", b); log("reserved-override lib", l); assert.equal(b, "dep-2\tneeds-decision\tdep-: spoken"); assert.equal(l, b);
}
// 9. CRLF meta: kind=ship\r\n is unknown in bash -> terminal close never applies; lib agrees; scan still resolves project
{
  const d = mk("crlf-meta", { "t.status": "needs-decision [key=a]: pick\ndone: x\n", "t.meta": "kind=ship\r\nproject=demo\r\n", ".wake-queue": "1\t1\tstale\tt\tstale: x\n" });
  const b = bashFold(d, "t"); const l = lib.foldStatusLog(d, "t"); const s = lib.scanStateDirectory(d);
  log("crlf-meta bash", b); log("crlf-meta lib", l); log("crlf-meta scan", S(s));
  assert.equal(b, "a\tneeds-decision\tpick"); assert.equal(l, b); assert.deepEqual(s.needsDecisionTasks, ["t"]);
}
// 10. torn read (Pi's rule) through injected inputs: version drift between stat and read refuses the scan
{
  const base = { queueText: "1\t1\tstale\tt\tstale: x\n", metas: [{ task: "t", project: "demo", window: "" }], readKind: () => "ship", env: lib.DEFAULT_FOLD_VOCABULARY, heartbeat: false, afk: false };
  const torn = lib.scopeForUnreadWake({ ...base, statStatus: () => ({ state: "ok", version: "v1" }), readStatusText: () => ({ state: "ok", text: "working: x\n", version: "v2" }) });
  log("torn version drift", S(torn)); assert.equal(torn.corrupted, true);
  const torn2 = lib.scopeForUnreadWake({ ...base, statStatus: () => ({ state: "ok", version: "v1" }), readStatusText: () => ({ state: "torn" }) });
  log("torn state", S(torn2)); assert.equal(torn2.corrupted, true);
  const refusedAfterStat = lib.scopeForUnreadWake({ ...base, statStatus: () => ({ state: "ok", version: "v1" }), readStatusText: () => ({ state: "refused" }) });
  log("refused after stat", S(refusedAfterStat)); assert.equal(refusedAfterStat.eligible, true);
  // cache eviction past 512
  const cache = new Map(); for (let i = 0; i < 600; i++) cache.set(`old${i}`, { version: "v", config: "c", decisionOwned: false });
  lib.scopeForUnreadWake({ ...base, cache, statStatus: () => ({ state: "ok", version: "v1" }), readStatusText: () => ({ state: "ok", text: "working: x\n", version: "v1" }) });
  log("cache size after insert at 600", cache.size); assert.equal(cache.size, 600); assert.equal(cache.has("old0"), false); assert.equal(cache.has("t"), true);
}
console.log("ALL SCAN SCENARIOS PASS");
