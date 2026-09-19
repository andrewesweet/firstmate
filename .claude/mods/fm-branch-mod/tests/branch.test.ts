// fm-branch-mod under `claude plugin test`: the version pin, the presence switch, the durable
// classification log, and the cover row a captain verdict writes for main.
//
// The world beneath the module is mocked noun by noun: the environment names a
// Firstmate home, an in-memory file system holds the home's state and config,
// and every process the module runs answers from a small table keyed on the
// script name, with a journal of every call so a test can read what the module
// wrote and to which file.
import { describe, expect, test, type Engine, type On } from "claude-code/testing";
import { mock, type MockClock } from "claude-code/testing";

const HOME = "/fm/home";
const STATE = `${HOME}/state`;
const CONFIG = `${HOME}/config`;
import { CLAUDE_CODE_PIN as PIN } from "../hooks/branch.ts";
const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };
const SESSION_ID = "0f3a9c2e-kit-session";

type Run = { argv: string[]; stdin?: string; env?: Record<string, string> };
type World = {
  clock: MockClock;
  files: Map<string, string>;
  runs: Run[];
  logs: string[];
  registered: string[];
  /** Prompts that reached the engine beneath the module, i.e. were not dropped. */
  submitted: string[];
  spawns: { subagentType?: string; name?: string; model?: string; background?: boolean; prompt?: string }[];
  toolCalls: Record<string, unknown>[];
  completions: { model: string; system: string; prompt: string; maxTokens?: number }[];
  /** Lines appended through the module's `sh -c ... cat >> "$f"` append, keyed by path. */
  appended: (path: string) => string[];
};

type WorldOptions = {
  version?: string;
  /** What the running-binary version probe answers; "" simulates a host without /proc. Defaults to `version`. */
  runningBinaryVersion?: string;
  files?: Record<string, string>;
  /** Extra environment variables the module reads beyond the kit's own. */
  env?: Record<string, string>;
  /** One answer per classifier call in order; the last one repeats. */
  classifierAnswer?: string | string[];
  /** One evidence bundle per fm-wake-evidence.sh run in order; the last one repeats. */
  evidence?: string | string[];
  /** One SendMessage result per tool.call in order; the last one repeats. */
  sendAnswer?: string | string[];
  /** When set, every SendMessage tool.call is denied with this string instead of answered. */
  sendDeny?: string;
  /** One jev shadow answer per fm-branch-shadow-jev.sh run in order; the last one repeats. */
  shadowAnswer?: string | string[];
  /** One pane answer per fm-branch-shadow-pane.sh run in order; the last one repeats. */
  paneAnswer?: string | string[];
};

function nth(values: string | string[] | undefined, index: number, fallback: string): string {
  if (values === undefined) return fallback;
  if (typeof values === "string") return values;
  return values[Math.min(index, values.length - 1)] ?? fallback;
}

function world(on: On, options: WorldOptions = {}): World {
  mock.env(on, { FM_HOME: HOME, CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: "1", ...options.env });
  const clock = mock.clock(on);
  const files = new Map<string, string>(Object.entries(options.files ?? {}));
  const runs: Run[] = [];
  const logs: string[] = [];
  const registered: string[] = [];
  const completions: World["completions"] = [];
  const appends = new Map<string, string[]>();
  const submitted: string[] = [];
  const spawns: World["spawns"] = [];
  const toolCalls: Record<string, unknown>[] = [];
  const version = options.version ?? PIN;
  const runningBinary = options.runningBinaryVersion !== undefined ? options.runningBinaryVersion : version;

  on("fs.read", async (_$, e) => {
    // The classifier system prompt is read from the plugin's own folder.
    if (e.path.endsWith("/classifier-system.txt")) return { value: "SYSTEM PROMPT FIXTURE" };
    return files.has(e.path) ? { value: files.get(e.path)! } : { deny: `ENOENT: ${e.path}` };
  });
  on("prompt.submit", async (_$, e) => {
    submitted.push(e.text);
    return { text: e.text };
  });
  on("fs.exists", async (_$, e) => ({ value: files.has(e.path) }));
  on("fs.write", async (_$, e) => {
    files.set(e.path, e.text);
    return { value: undefined };
  });
  on("fs.list", async (_$, e) => {
    const prefix = `${e.path.replace(/\/+$/, "")}/`;
    const names = [...files.keys()].filter((p) => p.startsWith(prefix) && !p.slice(prefix.length).includes("/"));
    return { value: names.map((p) => ({ name: p.slice(prefix.length), kind: "file" })) };
  });
  on("ui.log", async (_$, e) => {
    logs.push(e.text);
    return { value: undefined };
  });
  on("tool.register", async (_$, e) => {
    registered.push(e.name);
    return { value: undefined };
  });
  on("model.complete", async (_$, e) => {
    completions.push({ model: e.model, system: e.system, prompt: e.prompt, maxTokens: e.maxTokens });
    return { value: nth(options.classifierAnswer, completions.length - 1, '{"verdict":"routine","reason":"nothing new"}') };
  });
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("session.id", async () => ({ value: SESSION_ID }));
  on("agent.spawn", async (_$, e) => {
    // The event is Agent-tool shaped: subagent_type and run_in_background.
    spawns.push({ subagentType: e.subagent_type, name: e.name, model: e.model, background: e.run_in_background, prompt: e.prompt });
    // The kit answers a spawn with { model } only; the live engine adds agentId.
    return { model: e.model };
  });
  on("agent.list", async () => ({ value: [] }));
  on("tool.call", async (_$, e) => {
    toolCalls.push(e);
    if (options.sendDeny) return { deny: options.sendDeny };
    // No branch agent exists yet: the harness answers a send to an unknown name this way.
    return { result: nth(options.sendAnswer, toolCalls.length - 1, '{"success":false,"message":"no agent named fm-branch"}') };
  });
  on("process.run", async (_$, e) => {
    const argv = e.argv as string[];
    const init = (e.init ?? {}) as { stdin?: string; env?: Record<string, string> };
    const run: Run = { argv, stdin: init.stdin, env: init.env };
    runs.push(run);
    const answer = (stdout = "", exitCode = 0) => ({ value: { exitCode, stdout, stderr: "" } });
    if (argv[0] === "claude" && argv[1] === "--version") return answer(`${version} (Claude Code)\n`);
    if (argv[0] === "sh" && argv[1] === "-c") {
      // The running-binary version probe: the binary hosting the fake session,
      // which can differ from PATH `claude`; "" answers like a host without
      // /proc so the module must fall back.
      if (String(argv[2] ?? "").includes("/proc/$PPID/exe")) {
        if (runningBinary === "") return answer("", 1);
        return answer(`${runningBinary} (Claude Code)\n`);
      }
      // The module's own append: record the line under the target path.
      const path = argv[4];
      appends.set(path, [...(appends.get(path) ?? []), String(init.stdin ?? "")]);
      return answer();
    }
    const script = String(argv[1] ?? "").split("/").pop() ?? "";
    if (script === "fm-wake-evidence.sh") {
      const index = runs.filter((r) => r.argv[1]?.endsWith("fm-wake-evidence.sh")).length - 1;
      const fallback =
        `## task ${argv[2]} status bytes 0-38\n` +
        `## current state (bin/fm-crew-state.sh ${argv[2]})\n` +
        `state: working\n` +
        `## status lines appended since the last classified wake (NEW - judge these)\n` +
        `  done: PR https://x/1 checks green\n` +
        `## earlier lines, already handled by earlier wakes (HISTORY - never escalate these)\n` +
        `  (none)\n`;
      return answer(nth(options.evidence, index, fallback));
    }
    if (script === "fm-wake-grant.sh") return answer();
    if (script === "fm-branch-outcome.sh") return answer("7\n");
    if (script === "fm-branch-shadow-jev.sh") {
      const index = runs.filter((r) => r.argv[1]?.endsWith("fm-branch-shadow-jev.sh")).length - 1;
      return answer(nth(options.shadowAnswer, index, '{"ok":false,"unavailable":"http 503","model":"jev"}'));
    }
    if (script === "fm-branch-shadow-pane.sh") {
      const index = runs.filter((r) => r.argv[1]?.endsWith("fm-branch-shadow-pane.sh")).length - 1;
      return answer(nth(options.paneAnswer, index, '{"task":"t1","unavailable":"no readable pane evidence"}'));
    }
    return answer("", 1);
  });

  return {
    clock,
    files,
    runs,
    logs,
    registered,
    submitted,
    spawns,
    toolCalls,
    completions,
    appended: (path) => appends.get(path) ?? [],
  };
}

const CLASSIFICATIONS = `${STATE}/branch-mod-classifications.jsonl`;

/** A home with the mod switched on by the presence of state/.branch-mod-mode and one signal row queued for task t1. */
function armedHome(): Record<string, string> {
  return {
    [`${STATE}/.branch-mod-mode`]: "",
    [`${STATE}/.lock`]: "4242\n",
    [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\n",
    [`${STATE}/t1.status`]: "working: a\ndone: PR https://x/1 checks green\n",
    [`${STATE}/.wake-queue`]: "1700000000\t12\tsignal\tt1.status\tdone: PR https://x/1 checks green\n",
  };
}

const WAKE = `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nsignal: ${STATE}/t1.status\n`;

const startEvent = (w: World) =>
  w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line)).find((e) => e.kind === "session.start");

/** The detached shadow advisory only shares the microtask queue with delivery; two macrotask turns drain it. */
async function drained(): Promise<void> {
  await new Promise((r) => setTimeout(r, 0));
  await new Promise((r) => setTimeout(r, 0));
}

describe("version pin", () => {
  test("refuses to load on any other Claude Code version and passes every wake through", async ($: Engine, on: On) => {
    const w = world(on, { version: "2.1.271", files: armedHome() });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes("refusing to load on Claude Code 2.1.271") && l.includes(PIN))).toBe(true);
    expect(w.registered).toEqual([]);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE]);
    expect(w.completions.length).toBe(0);
    expect(w.appended(CLASSIFICATIONS)).toEqual([]);
  });

  test("loads on the pinned version and registers the report tools", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome() });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes(`loaded (enabled, home ${HOME}, Claude Code ${PIN})`))).toBe(true);
    expect(w.registered).toEqual(["fm_branch_report", "fm_branch_processed"]);
  });

  test("the binary hosting the session decides the pin when PATH claude differs", async ($: Engine, on: On) => {
    // The launcher execs the pinned binary by absolute path while the installer
    // symlink moved on: PATH answers a later release, the running binary the pin.
    const w = world(on, { version: "2.1.999", runningBinaryVersion: PIN, files: armedHome() });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes(`loaded (enabled, home ${HOME}, Claude Code ${PIN})`))).toBe(true);
    expect(w.registered).toEqual(["fm_branch_report", "fm_branch_processed"]);
    // The probe is issued first and answers, so PATH claude is never asked.
    expect(w.runs[0]?.argv).toEqual(["sh", "-c", 'exec "$(readlink /proc/$PPID/exe)" --version']);
    expect(w.runs.some((r) => r.argv[0] === "claude" && r.argv[1] === "--version")).toBe(false);
    // The load record names the source that decided and the probe's raw answer.
    const start = startEvent(w);
    expect(start?.data.version).toBe(PIN);
    expect(start?.data.pinSource).toBe("running binary");
    expect(start?.data.probe).toBe(`${PIN} (Claude Code)`);
  });

  test("a refusal records which source decided against the pin", async ($: Engine, on: On) => {
    const w = world(on, { version: PIN, runningBinaryVersion: "2.1.1", files: armedHome() });
    await $.session.start(sessionStart);
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    const refused = events.find((e) => e.kind === "pin.refused");
    expect(refused?.data).toEqual({ version: "2.1.1", pin: PIN, pinSource: "running binary", probe: "2.1.1 (Claude Code)" });
    expect(w.registered).toEqual([]);
  });

  test("PATH claude decides when the running binary's version is unavailable", async ($: Engine, on: On) => {
    // /proc is Linux-only: on a host without it the probe fails and the old
    // PATH call must still carry the pin check.
    const w = world(on, { version: PIN, runningBinaryVersion: "", files: armedHome() });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes(`loaded (enabled, home ${HOME}, Claude Code ${PIN})`))).toBe(true);
    expect(w.runs[0]?.argv[2]).toContain("/proc/$PPID/exe");
    expect(w.runs.some((r) => r.argv[0] === "claude" && r.argv[1] === "--version")).toBe(true);
    const start = startEvent(w);
    expect(start?.data.pinSource).toBe("PATH claude");
    expect(start?.data.probe).toBe("");
  });

  test("without state/.branch-mod-mode the module loads inert and passes every wake through unclassified", async ($: Engine, on: On) => {
    const files = armedHome();
    delete files[`${STATE}/.branch-mod-mode`];
    const w = world(on, { files });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes("loaded (inert: no state/.branch-mod-mode"))).toBe(true);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE]);
    expect(w.completions.length).toBe(0);
  });
});

describe("transcript persistence log", () => {
  const persistence = (w: World) => {
    const start = startEvent(w);
    return { on: start?.data.persistenceOn, cause: start?.data.persistenceCause };
  };

  test("session.start logs the persistence state and its cause", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome() });
    await $.session.start(sessionStart);
    expect(persistence(w)).toEqual({ on: true, cause: "default" });
  });

  test("an inherited CLAUDE_CODE_CHILD_SESSION marker logs persistence off", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), env: { CLAUDE_CODE_CHILD_SESSION: "1" } });
    await $.session.start(sessionStart);
    expect(persistence(w)).toEqual({ on: false, cause: "inherited CLAUDE_CODE_CHILD_SESSION marker" });
  });

  test("CLAUDE_CODE_FORCE_SESSION_PERSISTENCE logs persistence on over the marker", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), env: { CLAUDE_CODE_CHILD_SESSION: "1", CLAUDE_CODE_FORCE_SESSION_PERSISTENCE: "1" } });
    await $.session.start(sessionStart);
    expect(persistence(w)).toEqual({ on: true, cause: "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE" });
  });
});

describe("classification log", () => {
  test("every classifier call appends one record with task, evidence byte offsets, verdict, and model", async ($: Engine, on: On) => {
    const w = world(on, {
      files: { ...armedHome(), [`${CONFIG}/classifier-model`]: "haiku-4-5\n" },
      classifierAnswer: 'Sure. {"verdict":"captain","reason":"a done line with a PR URL"}',
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });

    expect(w.completions.length).toBe(1);
    expect(w.completions[0].model).toBe("haiku-4-5");
    expect(w.completions[0].maxTokens).toBe(200);

    const records = w.appended(CLASSIFICATIONS).map((line) => JSON.parse(line));
    expect(records.length).toBe(1);
    expect(records[0].tasks).toEqual(["t1"]);
    expect(records[0].seqs).toEqual(["12"]);
    expect(records[0].evidence).toEqual([{ task: "t1", from: 0, to: 38 }]);
    expect(records[0].verdict).toBe("captain");
    expect(records[0].model).toBe("haiku-4-5");
    expect(records[0].reason).toBe("a done line with a PR URL");
  });

  test("the classifier model defaults to haiku when config/classifier-model is absent", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome() });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.completions[0].model).toBe("haiku");
    const records = w.appended(CLASSIFICATIONS).map((line) => JSON.parse(line));
    expect(records[0].model).toBe("haiku");
  });

  test("a captain verdict passes the wake to main and writes a covering captain outcome row", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), classifierAnswer: '{"verdict":"captain","reason":"terminal line"}' });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv).toContain("--task");
    expect(cover!.argv[cover!.argv.indexOf("--task") + 1]).toBe("t1");
    expect(cover!.argv[cover!.argv.indexOf("--verdict") + 1]).toBe("captain");
    // No wake was granted here, so there is no in-flight wake identity to stamp.
    expect(cover!.argv).not.toContain("--wake-key");
    // Main handles the wake itself, so the branch was never granted or spawned.
    expect(w.submitted).toEqual([WAKE]);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-wake-grant.sh") && r.argv[2] === "publish")).toBe(false);
  });

  test("a passed wake main never acknowledged is passed again once the dedupe window has elapsed", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), classifierAnswer: '{"verdict":"captain","reason":"terminal line"}' });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE]);
    // The Stop hook re-blocks with the same banner while row 12 still sits in the queue.
    await w.clock.advance(91_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(w.submitted).toEqual([WAKE, WAKE]);
  });

  test("a passed row still queued after a restart goes back to main unclassified, even though its line is HISTORY to the classifier now", async ($: Engine, on: On) => {
    const w = world(on, {
      files: armedHome(),
      classifierAnswer: ['{"verdict":"captain","reason":"terminal line"}', '{"verdict":"routine","reason":"only a working line is new"}'],
      evidence: ["## task t1 status bytes 0-38\nNEW\n  done: PR https://x/1 checks green\n", "## task t1 status bytes 38-49\nHISTORY\n  done: PR https://x/1 checks green\nNEW\n  working: b\n"],
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE]);
    expect(w.completions.length).toBe(1);
    // Main's turn was interrupted before its drain: row 12 is still queued when
    // the next close adds row 13, and the session restarts in between.
    w.files.set(`${STATE}/t1.status`, "working: a\ndone: PR https://x/1 checks green\nworking: b\n");
    w.files.set(`${STATE}/.wake-queue`, "1700000000\t12\tsignal\tt1.status\tdone: PR https://x/1 checks green\n1700000060\t13\tsignal\tt1.status\tworking: b\n");
    await w.clock.advance(91_000);
    await $.session.start(sessionStart);
    const before = w.runs.length;
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE, WAKE]);
    expect(w.completions.length).toBe(1);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-wake-grant.sh") && r.argv[2] === "publish")).toBe(false);
    // The re-pass hands row 13 to main as a classifier pass would: its offset advances and a cover row is written.
    const after = w.runs.slice(before);
    expect(after.some((r) => r.argv[1]?.endsWith("fm-wake-evidence.sh") && r.argv[2] === "t1")).toBe(true);
    const cover = after.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv[cover!.argv.indexOf("--task") + 1]).toBe("t1");
    expect(cover!.argv[cover!.argv.indexOf("--verdict") + 1]).toBe("captain");
    expect(JSON.parse(w.files.get(`${STATE}/.branch-mod-passed`) ?? "[]")).toEqual(["12", "13"]);
    // Once main acknowledges (the rows leave the queue) the record is pruned and the classifier runs again.
    w.files.set(`${STATE}/.wake-queue`, "1700000120\t14\tsignal\tt1.status\tworking: c\n");
    await w.clock.advance(91_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(2);
    expect(JSON.parse(w.files.get(`${STATE}/.branch-mod-passed`) ?? "[]")).toEqual([]);
  });

  test("a stale row keyed by the task's window resolves to the task id for the offset advance and the cover row", async ($: Engine, on: On) => {
    const files = {
      ...armedHome(),
      [`${STATE}/t1.status`]: "working: a\nneeds-decision: [key=choice-1] pick one\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    };
    const w = world(on, { files });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nstale: fm-t1\n`, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(0);
    const evidence = w.runs.filter((r) => r.argv[1]?.endsWith("fm-wake-evidence.sh"));
    expect(evidence.map((r) => r.argv[2])).toEqual(["t1"]);
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv[cover!.argv.indexOf("--task") + 1]).toBe("t1");
    expect(w.runs.some((r) => r.argv.includes("fm-t1"))).toBe(false);
  });
});

// The open-decision fold v8 rules the mod ports from bin/fm-classify-lib.sh
// (_fm_decision_fold_line, last_status_line): a done:/failed: declaration closes
// the whole open set for ship and scout tasks but never for a secondmate, and
// the captain-held verdict reads the latest RECOGNIZED status event, not the
// last non-blank line. A stale wake on an owned task is passed straight to main
// (never classified, one covering captain outcome row); an unowned one is
// eligible and reaches the classifier.
describe("open-decision fold v8", () => {
  const STALE_WAKE = `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nstale: fm-t1\n`;

  function staleHome(status: string, kind?: string): Record<string, string> {
    return {
      [`${STATE}/.branch-mod-mode`]: "",
      [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: `project=demo\nwindow=fm-t1\n${kind ? `kind=${kind}\n` : ""}`,
      [`${STATE}/t1.status`]: status,
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    };
  }

  test("a done: line closes an open decision for a ship task, so the stale wake is classified instead of passed", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("needs-decision: [key=c1] pick one\ndone: shipped the branch\n") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append")).toBe(false);
  });

  test("a failed: line closes an open decision for a scout task", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("needs-decision: [key=c1] pick one\nfailed: upstream rejected the approach\n", "scout") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append")).toBe(false);
  });

  test("a secondmate's done: line cannot close an open decision", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("needs-decision: [key=c1] pick one\ndone: other work finished\n", "secondmate") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(0);
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv[cover!.argv.indexOf("--task") + 1]).toBe("t1");
    expect(cover!.argv[cover!.argv.indexOf("--verdict") + 1]).toBe("captain");
  });

  test("continuation prose after a captain-held: line does not un-hold the task (latest event, not last line)", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("needs-decision: [key=c1] pick one\ncaptain-held [key=c1]: filed for the captain\nwaiting on the captain to pick\n") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(0);
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv[cover!.argv.indexOf("--verdict") + 1]).toBe("captain");
  });

  test("a working: line after a captain-held: line un-holds the task", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("captain-held [key=c1]: filed for the captain\nworking: resumed while the captain thinks\n") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append")).toBe(false);
  });
});

describe("routine wake", () => {
  test("a routine verdict grants the wake and spawns the one persistent branch agent", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome() });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    // The kit's spawn answer carries no agentId, so the module cannot adopt
    // the agent here and hands the wake back to main; the live test
    // (tests/fm-branch-claude-mod-live-e2e.test.sh) is where the drop is
    // asserted. What the kit can prove is the grant and the spawn request.
    const publish = w.runs.find((r) => r.argv[1]?.endsWith("fm-wake-grant.sh") && r.argv[2] === "publish");
    expect(publish !== undefined).toBe(true);
    expect(publish!.argv.slice(-1)).toEqual(["12"]);
    expect(w.spawns.length).toBe(1);
    expect(w.spawns[0].subagentType).toBe("fm-branch-mod:fm-branch");
    expect(w.spawns[0].name).toBe("fm-branch");
    expect(w.spawns[0].background).toBe(true);
    expect(w.spawns[0].prompt?.startsWith("FIRSTMATE SUPERVISION WAKE: signal:")).toBe(true);
    expect(w.spawns[0].prompt?.includes("No earlier outcome exists for t1")).toBe(true);
    const records = w.appended(CLASSIFICATIONS).map((line) => JSON.parse(line));
    expect(records.length).toBe(1);
    expect(records[0].verdict).toBe("routine");
  });

  test("an unresumable branch agent rotates to a fresh named agent instead of re-sending to the dead one", async ($: Engine, on: On) => {
    // A bridge primary runs with transcript saving off, so SendMessage answers
    // this for every later wake; the module must rotate, not re-send or pass.
    const unresumable = '{"success":false,"message":"Agent \\"fm-branch\\" could not be resumed: No transcript found for agent ID: ade34056fb4d9ab91"}';
    const counters = { lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "ade34056fb4d9ab91" };
    const w = world(on, {
      files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) },
      sendAnswer: unresumable,
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    // Exactly one send against the dead agent, then one rotation spawn under
    // the next generation name (branchName() suffixes every generation above
    // 1). The kit's spawn answer carries no agentId, so the wake then passes
    // via the rotation's own spawn failure, exactly as a failed rotation must.
    expect(w.toolCalls.length).toBe(1);
    expect(w.spawns.length).toBe(1);
    expect(w.spawns[0].subagentType).toBe("fm-branch-mod:fm-branch");
    expect(w.spawns[0].name).toBe("fm-branch-2");
    expect(w.spawns[0].prompt?.startsWith("FIRSTMATE SUPERVISION WAKE: signal:")).toBe(true);
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    const rotated = events.find((e) => e.kind === "agent.rotated");
    // The send log names the resume target: the dead agent's id and the
    // primary session whose transcript resume would read.
    const send = events.find((e) => e.kind === "agent.send");
    expect(send?.data.agentId).toBe("ade34056fb4d9ab91");
    expect(send?.data.sessionId).toBe(SESSION_ID);
    expect(rotated?.data.why).toBe("unresumable");
    expect(rotated?.data.name).toBe("fm-branch-2");
    expect(rotated?.data.branchGeneration).toBe(2);
    expect(rotated?.data.sendDetail).toContain("could not be resumed");
    // The defect this pins: an unresumable agent never passes the wake to main
    // as a failed send again; only the rotation's own spawn failure can.
    expect(events.some((e) => e.kind === "wake.passed" && String(e.data.why).includes("delivery failed via send"))).toBe(false);
    // The dead agent id is dropped durably and the generation advanced, so the
    // next wake cannot re-adopt the unresumable agent.
    const saved = JSON.parse(w.files.get(`${STATE}/.branch-mod-counters`) ?? "{}");
    expect(saved.branchAgentId).toBe("");
    expect(saved.branchGeneration).toBe(2);
  });

  test("a SendMessage denied with the unresumable text also rotates", async ($: Engine, on: On) => {
    // The same resume failure surfaced as a hook deny (or thrown error) has no
    // result text; the deny string must be classified, not the empty text.
    const counters = { lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "ade34056fb4d9ab91" };
    const w = world(on, {
      files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) },
      sendDeny: 'Agent "fm-branch" could not be resumed: No transcript found for agent ID: ade34056fb4d9ab91',
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.toolCalls.length).toBe(1);
    expect(w.spawns.length).toBe(1);
    expect(w.spawns[0].name).toBe("fm-branch-2");
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    expect(events.find((e) => e.kind === "agent.rotated")?.data.why).toBe("unresumable");
    expect(events.some((e) => e.kind === "wake.passed" && String(e.data.why).includes("delivery failed via send"))).toBe(false);
  });
});

// The shadow advisory trial (config/classifier-shadow=jev): a detached,
// bounded question bundle to jev-latest over the state the mod just
// classified with, recorded one row per ablation variant in
// state/branch-mod-shadow.jsonl for bin/fm-branch-shadow-score.sh. It must
// never delay or alter the wake: off by default, silent when its helper is
// unavailable, and byte-honest about evidence it does not have.
describe("shadow advisory", () => {
  const SHADOW_LOG = `${STATE}/branch-mod-shadow.jsonl`;
  const JEV_OK =
    '{"ok":true,"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"routine","confidence":0.9,"probabilities":{"routine":0.9,"main":0.1}},"phase":{"type":"choice","choice":"finished_ready","confidence":0.8,"probabilities":{}},"severity":{"type":"score","score":1,"confidence":0.7,"probabilities":[0.1,0.8,0.1,0.0]},"no_new_outcome":{"type":"noul","noul":0.3}}}';
  const PANE_PRESENT =
    '{"task":"t1","tail":"pane last lines","observation":{"progressing":true,"seconds_since_last_activity":7,"busy_source":"pi-ext"}}';
  const shadowHome = (extra: Record<string, string> = {}): Record<string, string> => ({
    ...armedHome(),
    [`${CONFIG}/classifier-shadow`]: "jev\n",
    ...extra,
  });
  const shadowRuns = (w: World) => w.runs.filter((r) => r.argv[1]?.endsWith("fm-branch-shadow-jev.sh"));

  test("absent config/classifier-shadow means no shadow helper call and no shadow records", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), shadowAnswer: JEV_OK, paneAnswer: PANE_PRESENT });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(shadowRuns(w)).toEqual([]);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-branch-shadow-pane.sh"))).toBe(false);
    expect(w.appended(SHADOW_LOG)).toEqual([]);
  });

  test("a config naming another model stays off", async ($: Engine, on: On) => {
    const w = world(on, { files: shadowHome({ [`${CONFIG}/classifier-shadow`]: "other\n" }), shadowAnswer: JEV_OK, paneAnswer: PANE_PRESENT });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(shadowRuns(w)).toEqual([]);
    expect(w.appended(SHADOW_LOG)).toEqual([]);
  });

  test("jev records one row per ablation variant, each with the request bytes and policy floors", async ($: Engine, on: On) => {
    const w = world(on, { files: shadowHome(), shadowAnswer: JEV_OK, paneAnswer: PANE_PRESENT });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();

    const runs = shadowRuns(w);
    const records = w.appended(SHADOW_LOG).map((line) => JSON.parse(line));
    expect(records.map((r) => r.variant)).toEqual(["full", "without_current_state", "without_prior_outcomes", "without_pane_tail"]);
    expect(runs.length).toBe(4);
    const requests = runs.map((r) => JSON.parse(r.stdin ?? "{}"));
    expect(requests.map((q) => q.model)).toEqual(["jev-latest", "jev-latest", "jev-latest", "jev-latest"]);

    for (const r of records) {
      expect(r.kind).toBe("shadow");
      expect(r.wake).toBe("signal: /fm/home/state/t1.status");
      expect(r.seqs).toEqual(["12"]);
      // Durable wake identity: the fake queue row's epoch:seq, stamped on every
      // variant so the scorer can join these records to the outcome row the
      // granted wake's own report writes.
      expect(r.wakeKey).toBe("1700000000:12");
      expect(r.tasks).toEqual(["t1"]);
      expect(r.control).toBe(false);
      expect(r.unavailable).toBeNull();
      expect(r.model).toBe("jev-1.13.0");
      expect(r.requestBytes).toBeGreaterThan(0);
      expect(r.policy).toEqual({ choice_confidence_floor: 0.85, noul_grant_below: 0.15, noul_pass_above: 0.85 });
      expect(r.answers.route.choice).toBe("routine");
      expect(r.answers.route.confidence).toBe(0.9);
    }
    // The stdin body is exactly what the record measured.
    expect(records.map((r) => r.requestBytes)).toEqual(runs.map((r) => (r.stdin ?? "").length));

    // The full variant carries the assembled state; ablations drop exactly one key.
    expect(Object.keys(requests[0].state).sort()).toEqual(["current_state", "fresh_status", "pane", "unread_status", "wake"]);
    expect(Object.keys(requests[1].state).sort()).toEqual(["fresh_status", "pane", "unread_status", "wake"]);
    expect(Object.keys(requests[3].state).sort()).toEqual(["current_state", "fresh_status", "unread_status", "wake"]);
    expect(requests[0].state.pane).toEqual(JSON.parse(PANE_PRESENT));
    expect(requests[0].state.current_state[0].task).toBe("t1");

    // The bundle: route/phase/severity/no-new-outcome; no recovery question,
    // no stale_state without a stale reason, no candidates on a single-task wake.
    expect(Object.keys(requests[0].questions).sort()).toEqual(["no_new_outcome", "phase", "route", "severity"]);
  });

  test("fields with no evidence are omitted, never invented: no pane data makes full byte-identical to without_pane_tail", async ($: Engine, on: On) => {
    const w = world(on, { files: shadowHome(), shadowAnswer: JEV_OK });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();

    const bodies = shadowRuns(w).map((r) => r.stdin ?? "");
    expect(bodies[0]).toBe(bodies[3]);
    const full = JSON.parse(bodies[0]);
    expect(full.state.pane).toBeUndefined();
    // A dropped variant key still changes the bytes the helper saw.
    expect(bodies[0]).not.toBe(bodies[1]);
  });

  test("prior_outcomes carry provenance: source, same_wake, and already_presented", async ($: Engine, on: On) => {
    const outcomes = [
      JSON.stringify({ seq: 3, task: "t1", wake: "an earlier wake", verdict: "captain", summary: "Passed to main directly (classifier captain): decision needed" }),
      JSON.stringify({ seq: 4, task: "t1", wake: "another wake", verdict: "routine", summary: "branch shipped the fix" }),
      JSON.stringify({ seq: 5, task: "other", wake: "x", verdict: "routine", summary: "not this task" }),
    ].join("\n");
    const w = world(on, {
      files: shadowHome({ [`${STATE}/branch-outcomes.jsonl`]: `${outcomes}\n`, [`${STATE}/.branch-outcomes-cursor`]: "3\n" }),
      shadowAnswer: JEV_OK,
      paneAnswer: PANE_PRESENT,
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();

    const full = JSON.parse(shadowRuns(w)[0].stdin ?? "{}");
    expect(full.state.prior_outcomes).toEqual([
      { task: "t1", seq: 3, verdict: "captain", summary: "Passed to main directly (classifier captain): decision needed", source: "classifier_pass", same_wake: false, already_presented: true },
      { task: "t1", seq: 4, verdict: "routine", summary: "branch shipped the fix", source: "accepted_branch", same_wake: false, already_presented: false },
    ]);
    // The wake's own reason marks the same-wake row.
    const same = JSON.parse(shadowRuns(w)[0].stdin ?? "{}");
    expect(same.state.prior_outcomes.every((p: any) => p.same_wake === false)).toBe(true);
  });

  test("a compound wake carries one provenance-bearing Noul per candidate; a stale wake carries stale_state", async ($: Engine, on: On) => {
    const files = shadowHome({
      [`${STATE}/t2.meta`]: "project=demo\nwindow=fm-t2\n",
      [`${STATE}/t2.status`]: "working: b\n",
      [`${STATE}/.wake-queue`]: "1700000000\t12\tsignal\tt1.status\tdone: PR https://x/1 checks green\n1700000000\t13\tsignal\tt2.status\tworking: b\n",
    });
    const w = world(on, { files, shadowAnswer: JEV_OK, paneAnswer: PANE_PRESENT });
    await $.session.start(sessionStart);
    await $.prompt.submit({
      text: `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nsignal: ${STATE}/t1.status\nsignal: ${STATE}/t2.status\n`,
      origin: { kind: "task-notification" },
    });
    await drained();

    const full = JSON.parse(shadowRuns(w)[0].stdin ?? "{}");
    expect(full.state.wake).toContain("t1.status");
    const cands = full.questions.candidates;
    expect(Object.keys(cands).sort()).toEqual(["t1", "t2"]);
    expect(cands.t1.type).toBe("noul");
    expect(cands.t1.instructions.candidate).toBe("t1");
    expect(cands.t1.instructions.fresh_lines.length).toBeGreaterThan(0);
    expect(cands.t1.instructions.fresh_lines[0].id).toMatch(/^t1:[0-9]+-[0-9]+$/);
    expect(cands.t2.instructions.prior_outcome).toBeNull();
    expect(full.questions.stale_state).toBeUndefined();
    expect(Object.keys(full.questions)).not.toContain("recovery");
  });

  test("a stale wake carries the stale_state question and never a recovery question", async ($: Engine, on: On) => {
    const stale = world(on, {
      files: {
        ...armedHome(),
        [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
        [`${CONFIG}/classifier-shadow`]: "jev\n",
      },
      shadowAnswer: JEV_OK,
      paneAnswer: PANE_PRESENT,
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nstale: fm-t1\n`, origin: { kind: "task-notification" } });
    await drained();
    const staleFull = JSON.parse(shadowRuns(stale)[0].stdin ?? "{}");
    expect(staleFull.questions.stale_state.type).toBe("choice");
    expect(Object.keys(staleFull.questions)).not.toContain("recovery");
  });

  test("a wake-queue row with a non-numeric epoch is unsafe scope: passed to main untouched, no shadow record, no wake key stamped", async ($: Engine, on: On) => {
    const w = world(on, {
      files: shadowHome({ [`${STATE}/.wake-queue`]: "not-an-epoch\t12\tsignal\tt1.status\tdone: PR https://x/1 checks green\n" }),
      shadowAnswer: JEV_OK,
      paneAnswer: PANE_PRESENT,
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();

    expect(w.submitted).toEqual([WAKE]);
    expect(w.completions.length).toBe(0);
    expect(w.spawns.length).toBe(0);
    expect(shadowRuns(w)).toEqual([]);
    expect(w.appended(SHADOW_LOG)).toEqual([]);
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    expect(events.some((e) => e.kind === "wake.passed" && e.data.why === "scope unsafe")).toBe(true);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv.includes("--wake-key"))).toBe(false);
  });

  test("an unavailable helper records unavailable per variant and never touches the delivery", async ($: Engine, on: On) => {
    const w = world(on, { files: shadowHome() });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();

    const records = w.appended(SHADOW_LOG).map((line) => JSON.parse(line));
    expect(records.length).toBe(4);
    for (const r of records) {
      expect(r.unavailable).toBe("http 503");
      expect(r.model).toBeUndefined();
      expect(r.answers).toBeUndefined();
      expect(r.requestBytes).toBeGreaterThan(0);
    }
    // The wake itself was still granted and spawned: the shadow changed nothing.
    expect(w.spawns.length).toBe(1);
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    expect(events.some((e) => e.kind === "wake.passed" && String(e.data.why).includes("shadow"))).toBe(false);
  });

  test("every tenth wake repeats the full variant as the raw-call-noise control", async ($: Engine, on: On) => {
    const counters = { lockPid: "4242", wakeCounter: 9, spawnCount: 1, sendCount: 0, branchGeneration: 1, branchAgentId: "" };
    const w = world(on, {
      files: shadowHome({ [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) }),
      shadowAnswer: JEV_OK,
      paneAnswer: PANE_PRESENT,
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();

    const records = w.appended(SHADOW_LOG).map((line) => JSON.parse(line));
    expect(records.map((r) => [r.variant, r.repeat])).toEqual([
      ["full", 1],
      ["without_current_state", 1],
      ["without_prior_outcomes", 1],
      ["without_pane_tail", 1],
      ["full", 2],
    ]);
    expect(records[4].control).toBe(true);
    // The two full calls carry byte-identical requests: only sampling noise can differ.
    const bodies = shadowRuns(w).map((r) => r.stdin ?? "");
    expect(bodies[0]).toBe(bodies[4]);
    // An ordinary wake stays at four.
    const before = w.appended(SHADOW_LOG).length;
    w.files.set(`${STATE}/t1.status`, "working: a\ndone: PR https://x/1 checks green\nworking: c\n");
    w.files.set(`${STATE}/.wake-queue`, "1700000120\t14\tsignal\tt1.status\tworking: c\n");
    await w.clock.advance(91_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(w.appended(SHADOW_LOG).length - before).toBe(4);
  });
});
