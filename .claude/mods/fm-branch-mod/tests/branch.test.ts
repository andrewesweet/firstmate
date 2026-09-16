// fm-branch-mod under `claude plugin test`: the version pin, the durable
// classification log, and the cover row a captain verdict writes for main.
//
// The world beneath the module is mocked noun by noun: the environment names a
// Firstmate home, an in-memory file system holds the home's state and config,
// and every process the module runs answers from a small table keyed on the
// script name, with a journal of every call so a test can read what the module
// wrote and to which file.
import { describe, expect, test, type Engine, type On } from "claude-code/testing";
import { mock } from "claude-code/testing";

const HOME = "/fm/home";
const STATE = `${HOME}/state`;
const CONFIG = `${HOME}/config`;
const PIN = "2.1.273";
const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

type Run = { argv: string[]; stdin?: string; env?: Record<string, string> };
type World = {
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
  classifierAnswer?: string;
  evidence?: string;
};

function world(on: On, options: WorldOptions = {}): World {
  mock.env(on, { FM_HOME: HOME, CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: "1" });
  mock.clock(on);
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
    return { value: options.classifierAnswer ?? '{"verdict":"routine","reason":"nothing new"}' };
  });
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("agent.spawn", async (_$, e) => {
    // The event is Agent-tool shaped: subagent_type and run_in_background.
    spawns.push({ subagentType: e.subagent_type, name: e.name, model: e.model, background: e.run_in_background, prompt: e.prompt });
    // The kit answers a spawn with { model } only; the live engine adds agentId.
    return { model: e.model };
  });
  on("agent.list", async () => ({ value: [] }));
  on("tool.call", async (_$, e) => {
    toolCalls.push(e);
    // No branch agent exists yet: the harness answers a send to an unknown name this way.
    return { result: '{"success":false,"message":"no agent named fm-branch"}' };
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
    if (script === "fm-wake-evidence.sh") return answer(options.evidence ?? `## task ${argv[2]} status bytes 0-38\ndone: PR https://x/1 checks green\n`);
    if (script === "fm-wake-grant.sh") return answer();
    if (script === "fm-branch-outcome.sh") return answer("7\n");
    return answer("", 1);
  });

  return {
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

/** A home with the mod switched on, the classifier armed, and one signal row queued for task t1. */
function armedHome(): Record<string, string> {
  return {
    [`${STATE}/.branch-mod-mode`]: "drop\n",
    [`${STATE}/.branch-mod-classifier`]: "",
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
    expect(w.logs.some((l) => l.includes(`loaded (mode drop, home ${HOME}, Claude Code ${PIN})`))).toBe(true);
    expect(w.registered).toEqual(["fm_branch_report", "fm_branch_processed"]);
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
    const records = w.appended(CLASSIFICATIONS).map((line) => JSON.parse(line));
    expect(records.length).toBe(1);
    expect(records[0].verdict).toBe("routine");
  });
});
