// Drives runShadowAdvisory with a REAL runScript: spawns the repo's
// bin/fm-branch-shadow-jev.sh (curl -> TS_BASE) for a two-task compound wake
// and writes the shadow records to a real shadow.jsonl.
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
const [libPath, binDir, stateDir, shadowLog] = process.argv.slice(2);
const lib = await import(pathToFileURL(libPath).href);
const runScript = (argv, opts) => new Promise((resolve) => {
  const p = spawn(argv[0], argv.slice(1), { env: process.env });
  let stdout = "", stderr = "";
  p.stdout.on("data", (c) => (stdout += c)); p.stderr.on("data", (c) => (stderr += c));
  p.on("close", (code) => resolve({ exitCode: code ?? 1, stdout, stderr }));
  if (opts?.stdin) p.stdin.end(opts.stdin); else p.stdin.end();
});
const deps = {
  paths: { bin: binDir, state: stateDir },
  readFile: async () => { throw new Error("no file"); },
  hasOpenCall: async () => false,
  runScript,
  readConfig: async (name, fb) => (name === "classifier-shadow" ? "jev" : fb),
  appendShadowRecord: async (line) => appendFileSync(shadowLog, line + "\n"),
  onShadowError: (kind, e) => console.error("shadow error", kind, String(e)),
  clock: { now: () => Date.now(), iso: () => new Date().toISOString() },
};
await lib.runShadowAdvisory(deps, {
  wake: "heartbeat: two", seqs: ["6"], wakeKey: "wk-live", tasks: ["ship-a", "ship-b"], wakeNo: 3,
  evidence: [
    { task: "ship-a", from: 0, to: 12, text: "## status lines appended since last outcome\n  done: a\n" },
    { task: "ship-b", from: 0, to: 12, text: "## status lines appended since last outcome\n  done: b\n" },
  ],
});
