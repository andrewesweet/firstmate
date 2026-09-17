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
  /** When set, every SendMessage tool.call is denied with this string instead of answered. */
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

describe("shell v8 parity", () => {
  const STALE_WAKE = `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nstale: fm-t1\n`;
  test("nd-done-ship [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone: shipped\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("nd-done-scout [scout] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=scout\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone: shipped\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("nd-failed-ship [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\nfailed: bust\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("nd-done-secondmate [secondmate] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=secondmate\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone: other work\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("nd-done-nometa [NOMETA] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone: shipped\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("nd-done-metanokind [NOKIND] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\\nwindow=fm-t1\\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone: shipped\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("nd-done-weirdkind [weird] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=weird\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone: shipped\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("nd-done-nocolon-key [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone [key=c1] shipped\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("nd-done-bareword [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("nd-Done-case [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\nDone: shipped\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("nd-done-then-nd [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\ndone: shipped\nneeds-decision: [key=c2] again\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("nd-resolved [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] pick one\nresolved [key=c1]: chose a\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("nd2-resolve1 [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] a\nneeds-decision: [key=c2] b\nresolved [key=c1]: ok\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("nd-corr-done [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision corr=0123456789abcdef [key=c1]: q\ndone: fin\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("nd-done-prose [secondmate] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=secondmate\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] q\ndone: fin\n  and some continuation prose\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("held-prose [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] q\ncaptain-held [key=c1]: filed\nwaiting on the captain\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("held-working [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "captain-held [key=c1]: filed\nworking: resumed\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("held-prready [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "captain-held [key=c1]: filed\nPR ready for review\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("held-prose-mentions-done [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "captain-held [key=c1]: filed\nthe mate said done: nope\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("held-DONE-upper [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "captain-held [key=c1]: filed\nDONE: caps\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("held-note [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "captain-held [key=c1]: filed\nnote: fyi\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("held-blank-tail [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "captain-held [key=c1]: filed\n   \n\t\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("held-then-nd [ship] shell owned=1", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "captain-held [key=c1]: filed\nneeds-decision: [key=c2] next\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("1");
  });
  test("prose-only [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "just some prose\nmore prose\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("blocked-only [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "blocked: [key=c1] waiting on infra\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("nd-done-secondmate-then-resolved [secondmate] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=secondmate\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=c1] q\ndone: x\nresolved [key=c1]: ok\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("nd-badkey-done [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "needs-decision: [key=bad key!] q\ndone: x\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
  test("held-merged-legacy [ship] shell owned=0", async ($: Engine, on: On) => {
    const w = world(on, { files: {
      [`${STATE}/.branch-mod-mode`]: "", [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\nkind=ship\n",
      [`${STATE}/t1.status`]: "captain-held [key=c1]: filed\nmerged into main\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    } });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    const modOwned = w.completions.length === 0 && cover !== undefined && cover.argv[cover.argv.indexOf("--verdict") + 1] === "captain";
    const modFree = w.completions.length === 1 && cover === undefined;
    expect(modOwned ? "1" : modFree ? "0" : "neither").toBe("0");
  });
});
