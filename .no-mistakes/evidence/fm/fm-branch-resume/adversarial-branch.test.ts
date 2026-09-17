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
const PIN = "2.1.273";
const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

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
  files?: Record<string, string>;
  /** One answer per classifier call in order; the last one repeats. */
  classifierAnswer?: string | string[];
  /** One evidence bundle per fm-wake-evidence.sh run in order; the last one repeats. */
  evidence?: string | string[];
  /** One SendMessage result per tool.call in order; the last one repeats. */
  sendAnswer?: string | string[];
  /** agentId the mocked spawn answers with; absent means the kit's bare { model }. */
  spawnAgentId?: string;
  /** When set, every SendMessage tool.call answers with this deny string instead of a result. */
  sendDeny?: string;
};

function nth(values: string | string[] | undefined, index: number, fallback: string): string {
  if (values === undefined) return fallback;
  if (typeof values === "string") return values;
  return values[Math.min(index, values.length - 1)] ?? fallback;
}

function world(on: On, options: WorldOptions = {}): World {
  mock.env(on, { FM_HOME: HOME, CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: "1" });
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
  on("agent.spawn", async (_$, e) => {
    // The event is Agent-tool shaped: subagent_type and run_in_background.
    spawns.push({ subagentType: e.subagent_type, name: e.name, model: e.model, background: e.run_in_background, prompt: e.prompt });
    // The kit answers a spawn with { model } only; the live engine adds agentId.
    return options.spawnAgentId ? { model: e.model, agentId: options.spawnAgentId } : { model: e.model };
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
      // The module's own append: record the line under the target path.
      const path = argv[4];
      appends.set(path, [...(appends.get(path) ?? []), String(init.stdin ?? "")]);
      return answer();
    }
    const script = String(argv[1] ?? "").split("/").pop() ?? "";
    if (script === "fm-wake-evidence.sh") {
      const index = runs.filter((r) => r.argv[1]?.endsWith("fm-wake-evidence.sh")).length - 1;
      return answer(nth(options.evidence, index, `## task ${argv[2]} status bytes 0-38\ndone: PR https://x/1 checks green\n`));
    }
    if (script === "fm-wake-grant.sh") return answer();
    if (script === "fm-branch-outcome.sh") return answer("7\n");
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

  test("ADV pre-fix event log: dump events for the unresumable case", async ($: Engine, on: On) => {
    const unresumable = '{"success":false,"message":"Agent \\"fm-branch\\" could not be resumed: No transcript found for agent ID: ade34056fb4d9ab91"}';
    const counters = { lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "ade34056fb4d9ab91" };
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) }, sendAnswer: unresumable, spawnAgentId: "fresh0001" });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    console.log("EVENTS-ROTATE-OK\n" + w.appended(`${STATE}/branch-mod-events.jsonl`).join(""));
    console.log("COUNTERS-ROTATE-OK " + w.files.get(`${STATE}/.branch-mod-counters`));
    console.log("SUBMITTED-ROTATE-OK " + JSON.stringify(w.submitted));
    // With a live-shaped spawn (agentId present) the wake is dropped from main entirely.
    expect(w.submitted).toEqual([]);
    expect(w.spawns.length).toBe(1);
    expect(w.spawns[0].name).toBe("fm-branch-2");
    const saved = JSON.parse(w.files.get(`${STATE}/.branch-mod-counters`) ?? "{}");
    expect(saved.branchAgentId).toBe("fresh0001");
    expect(saved.branchGeneration).toBe(2);
    expect(saved.spawnCount).toBe(2);
  });

  test("ADV a second wake after rotation is sent to fm-branch-2 and does not spawn again", async ($: Engine, on: On) => {
    const unresumable = '{"success":false,"message":"Agent \\"fm-branch\\" could not be resumed: No transcript found for agent ID: ade34056fb4d9ab91"}';
    const counters = { lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "ade34056fb4d9ab91" };
    const files = { ...armedHome(), [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) };
    const w = world(on, { files, sendAnswer: [unresumable, '{"success":true,"resumedAgentId":"fresh0001"}'], spawnAgentId: "fresh0001" });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.spawns.length).toBe(1);
    // A second, distinct queue row so the dedupe window does not swallow the wake.
    w.files.set(`${STATE}/t1.status`, "working: a\ndone: PR https://x/1 checks green\ndone: PR https://x/2 checks green\n");
    w.files.set(`${STATE}/.wake-queue`, "1700000000\t12\tsignal\tt1.status\tdone: PR https://x/1 checks green\n1700000100\t13\tsignal\tt1.status\tdone: PR https://x/2 checks green\n");
    w.clock.advance?.(120000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    console.log("TOOLCALLS-2ND " + JSON.stringify(w.toolCalls.map((c: any) => c.to)));
    console.log("EVENTS-2ND\n" + w.appended(`${STATE}/branch-mod-events.jsonl`).join(""));
    expect(w.spawns.length).toBe(1);
    expect((w.toolCalls.at(-1) as any).to).toBe("fm-branch-2");
    expect(w.submitted).toEqual([]);
  });

  test("ADV a send failure that is not an unresumable/unknown agent still passes to main and does not rotate", async ($: Engine, on: On) => {
    const busy = '{"success":false,"message":"Agent \\"fm-branch\\" rejected the message: mailbox full"}';
    const counters = { lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "ade34056fb4d9ab91" };
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) }, sendAnswer: busy, spawnAgentId: "fresh0001" });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    console.log("EVENTS-BUSY\n" + w.appended(`${STATE}/branch-mod-events.jsonl`).join(""));
    expect(w.spawns.length).toBe(0);
    expect(events.some((e) => e.kind === "agent.rotated")).toBe(false);
    expect(events.some((e) => e.kind === "wake.passed" && String(e.data.why).includes("delivery failed via send"))).toBe(true);
    expect(w.submitted).toEqual([WAKE]);
    const saved = JSON.parse(w.files.get(`${STATE}/.branch-mod-counters`) ?? "{}");
    expect(saved.branchGeneration).toBe(1);
    expect(saved.branchAgentId).toBe("ade34056fb4d9ab91");
  });

  test("ADV a thrown/denied SendMessage carrying the unresumable text also rotates", async ($: Engine, on: On) => {
    const counters = { lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "ade34056fb4d9ab91" };
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) }, spawnAgentId: "fresh0001", sendDeny: 'Agent "fm-branch" could not be resumed: No transcript found for agent ID: ade34056fb4d9ab91' });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    console.log("EVENTS-DENY\n" + w.appended(`${STATE}/branch-mod-events.jsonl`).join(""));
    expect(w.spawns.length).toBe(1);
    expect(w.spawns[0].name).toBe("fm-branch-2");
  });
});
