// Drives the real classifier core against the real bin/fm-wake-evidence.sh
// gatherer, writing real records into a real classification log.
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import { classifyWake } from "/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M34YZG0WVE132XNJ5QJGJWDP/.claude/mods/fm-branch-mod/lib/fm-branch-classifier.ts";

const ROOT = "/home/andre/.no-mistakes/worktrees/feb37d45d9da/01M34YZG0WVE132XNJ5QJGJWDP";
const STATE = process.env.DRIVE_STATE;
const VERDICT = process.env.DRIVE_VERDICT || "routine";
const TASK = process.env.DRIVE_TASK;
const LOG = `${STATE}/branch-mod-classifications.jsonl`;

const deps = {
  paths: { bin: `${ROOT}/bin` },
  runScript: (argv, opts) => new Promise((res) => {
    const p = spawn(argv[0], argv.slice(1), { cwd: ROOT, env: { ...process.env, FM_STATE_OVERRIDE: STATE, FM_HOME: STATE + "/home", FM_ROOT_OVERRIDE: ROOT } });
    let out = "", err = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("close", (code) => res({ exitCode: code ?? 1, stdout: out, stderr: err }));
  }),
  readSystemPrompt: async () => "classifier system prompt",
  readConfiguredModel: async () => "haiku",
  readDefaultModel: async () => "haiku",
  // Host seam: the model call. The verdict under test is supplied so the
  // scorer's label-vs-verdict comparison is deterministic.
  complete: async () => JSON.stringify({ verdict: VERDICT, reason: "driven" }),
  clock: { now: () => 0, iso: () => "2026-09-22T00:00:00Z" },
};

const outcome = await classifyWake(deps, { wake: `signal: ${TASK}`, tasks: [TASK], seqs: ["1"] });
appendFileSync(LOG, outcome.recordLine);
const e = outcome.record.evidence[0];
console.log(JSON.stringify({ task: e.task, from: e.from, to: e.to, text_len: e.text_len, captured_chars: e.text.length, text_cap: outcome.record.text_cap, verdict: outcome.record.verdict }));
