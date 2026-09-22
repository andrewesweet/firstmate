// One owner for the supervision-branch pre-branch classifier core, shared by
// the Pi supervision-branch extension (.pi/extensions/fm-branch-supervision.ts)
// and the Claude Code supervision-branch mod
// (.claude/mods/fm-branch-mod/hooks/branch.ts).
//
// This module owns, once: the evidence-bundle byte-range parse of
// bin/fm-wake-evidence.sh output and its failure text, the classifier prompt
// construction, the deterministic verb route (the recognised-verb whitelist
// that short-circuits the model call on every-verb new lines), the
// model-answer interpretation rule (verdict whitelist,
// unparsed and failed-call fallbacks), the durable classification-log record
// shape and its serialization, and the classifier-pass covering-outcome rule
// (the "Passed to main directly (...)" summary, its append argv, and the
// bare evidence gatherer that advances a task's classifier offset).
//
// Host seams - declared, deliberately not unified:
//   - THE MODEL CALL. The mod calls $.model.complete; the Pi extension
//     resolves the configured model name against its isolated runtime and
//     calls pi-ai's completeSimple. Both receive the same request object
//     ({model, system, prompt, maxTokens}) and return the answer text; a
//     rejection is a failed call and routes the wake to main. The one
//     shared piece of that policy is model resolution: the explicit
//     config/classifier-model name wins, otherwise each host's own default
//     (haiku on the mod, the supervision branch's own model on Pi), then
//     the model-not-found fallback below:
//   - SCRIPT SPAWNS. The host binds cwd and environment; this module builds
//     the argv (bash, the script under paths.bin, its arguments) and owns
//     the timeouts.
//   - FILE READS AND APPENDS. The host reads the classifier system prompt
//     (paths differ per host) and the model config, and appends the
//     serialized record line to state/branch-mod-classifications.jsonl with
//     its own rotation and failure logging.
//   - THE CLOCK is injected, so tests pin record bytes without waiting.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

/** One task's bash-gathered evidence bundle: the status byte range the bundle
 * covers (both -1 when the gatherer named no range) and the bundle text. */
export interface ClassifierEvidence {
  task: string;
  from: number;
  to: number;
  text: string;
}

/** The classifier's verdict for one wake. Anything outside the whitelist is
 * reported as "uncertain" so an unexpected answer passes the wake to main. */
export const CLASSIFIER_VERDICTS = ["routine", "captain", "uncertain"];

export const CLASSIFIER_MAX_TOKENS = 200;
/** bin/fm-wake-evidence.sh per-task timeout, as the mod has always run it. */
export const CLASSIFIER_EVIDENCE_TIMEOUT_MS = 25_000;
/** The durable record keeps at most this many characters of the raw answer. */
export const CLASSIFIER_ANSWER_CAP = 400;
/** The durable record captures at most this many characters of each evidence
 * bundle beside its byte range, so a classification stays scorable after
 * teardown deletes the status log the range points at. The cap is measured,
 * not round: the recorded log's per-bundle status byte ranges run p50 90 /
 * p90 812 / p99 4,197 bytes (319 records, 469 bundles, measured 2026-09-28),
 * and the gatherer bounds every bundle at a 1,500-byte state section plus a
 * 6,000-byte NEW block plus fixed markers, so 8,192 captures over 99% of
 * bundles whole while bounding every record entry. */
export const CLASSIFIER_EVIDENCE_TEXT_CAP = 8192;

export interface ClassifierResult {
  verdict: string;
  reason: string;
  ms: number;
  promptChars: number;
  answer: string;
  /** The model actually asked, or null when the host resolved none. */
  model: string | null;
  evidence: ClassifierEvidence[];
}

export interface ClassifierRecord {
  t: string;
  wake: string;
  tasks: string[];
  seqs: string[];
  /** The byte range stays the scoring reference exactly as it always was;
   * `text` is the bounded copy of the bundle the model judged and `text_len`
   * the length it judged, so text_len - text.length is what the cap omitted
   * and a copy shorter than text_cap is always whole. */
  evidence: Array<{ task: string; from: number; to: number; text: string; text_len: number }>;
  /** The capture cap every evidence text above was bounded by. */
  text_cap: number;
  verdict: string;
  reason: string;
  model: string | null;
  ms: number;
  answer: string;
}

/** The model-not-found error class: the configured or default classifier
 * model name does not resolve on this host. This class, and only this
 * class, triggers the one-shot fallback retry in classifyWake; every other
 * failure surfaces exactly as a failed call always has. Each host renders
 * the class in its own failure text - Pi names the model as not found or
 * unknown, Claude Code's $.model.complete reports "the request to <model>
 * failed (HTTP 404)" - so the predicate matches the known phrasings rather
 * than one host's exact string. */
export function isClassifierModelNotFoundError(error: string): boolean {
  return /model.*not found|not found.*model|unknown model|invalid model|not a valid model|HTTP 404/i.test(error);
}

/** The host surface the classifier runs against. runScript binds the host's
 * cwd and environment; the three model reads are the host's own values,
 * while the resolution rule itself (explicit wins, else default) is owned
 * by classifyWake below. */
export interface ClassifierDeps {
  paths: { bin: string };
  runScript(argv: string[], opts: { timeoutMs: number }): Promise<{ exitCode: number; stdout: string; stderr: string }>;
  readSystemPrompt(): Promise<string>;
  /** The explicit config/classifier-model name, or null when the operator
   * set none. */
  readConfiguredModel(): Promise<string | null>;
  /** The host's own default model name: haiku on Claude Code, the
   * supervision branch's own model on Pi (the pin, else the main session's
   * model), or null when the host cannot resolve one. It is also the target
   * of the one-shot model-not-found retry when a configured name fails. */
  readDefaultModel(): Promise<string | null>;
  complete(req: { model: string; system: string; prompt: string; maxTokens: number }): Promise<string>;
  clock: { now(): number; iso(): string };
}

// The classifier system prompt is read once per module lifetime, exactly as
// each host memoized it before this extraction.
let cachedSystemPrompt: string | null = null;

/** Behavior-neutral test seam: clears the memoized system prompt. */
export function __resetClassifierSystemPrompt(): void {
  cachedSystemPrompt = null;
}

async function classifierSystemPrompt(deps: ClassifierDeps): Promise<string> {
  if (!cachedSystemPrompt) cachedSystemPrompt = await deps.readSystemPrompt();
  return cachedSystemPrompt;
}

/** The "## task <task> status bytes <from>-<to>" first-line parse. Returns
 * null when the bundle names no range. */
export function evidenceStatusRange(stdout: string): { from: number; to: number } | null {
  const m = stdout.match(/status bytes ([0-9]+)-([0-9]+)/);
  return m ? { from: Number(m[1]), to: Number(m[2]) } : null;
}

/** The evidence text a failed gatherer contributes to the prompt, so a
 * failed gather is judgeable evidence rather than a silent gap. */
export function evidenceFailureBundle(task: string, stderr: string): string {
  return `## task ${task}\n(evidence gatherer failed: ${String(stderr).slice(0, 300)})`;
}

/** One task's evidence bundle through bin/fm-wake-evidence.sh. */
export async function gatherClassifierEvidence(deps: ClassifierDeps, task: string): Promise<ClassifierEvidence> {
  const r = await deps.runScript(["bash", `${deps.paths.bin}/fm-wake-evidence.sh`, task], {
    timeoutMs: CLASSIFIER_EVIDENCE_TIMEOUT_MS,
  });
  if (r.exitCode !== 0) return { task, from: -1, to: -1, text: evidenceFailureBundle(task, r.stderr) };
  const range = evidenceStatusRange(r.stdout);
  return { task, from: range ? range.from : -1, to: range ? range.to : -1, text: r.stdout };
}

/** The user prompt of a classifier call, byte-stable: the wake text, the
 * evidence bundles in task order, and the one-JSON-line instruction. */
export function buildClassifierPrompt(wake: string, evidence: ClassifierEvidence[]): string {
  return `WAKE:\n${wake}\n\nEVIDENCE (bash-gathered, read-only):\n\n${evidence.map((b) => b.text).join("\n")}\n\nAnswer with the one JSON line.`;
}

/** The model-answer rule, stated once: a failed call or a malformed answer is
 * verdict "uncertain" (the wake goes to main); a whitelisted verdict is
 * trusted and every answer's reason string is carried through. */
export function interpretClassifierAnswer(answer: string, completeError: string | null): { verdict: string; reason: string } {
  let verdict = "uncertain";
  let why = completeError !== null ? `model.complete failed: ${completeError}` : "unparsed";
  const s = answer.indexOf("{");
  const e = answer.lastIndexOf("}");
  if (s >= 0 && e > s) {
    try {
      const j = JSON.parse(answer.slice(s, e + 1));
      if (CLASSIFIER_VERDICTS.includes(j.verdict)) verdict = j.verdict;
      why = String(j.reason ?? "");
    } catch {
      why = "unparsed";
    }
  }
  return { verdict, reason: why };
}

/** The covering summary a classifier pass writes into the outcome store, so
 * the branch's next wake note and the drain backstop read main's direct
 * handling as covered. The shadow module's provenance test matches the same
 * prefix. */
export function passedToMainSummary(why: string, classifierReason: string): string {
  return `Passed to main directly (${why}): ${classifierReason}`;
}

/** The store append argv of one classifier-pass covering row. */
export function classifierPassCoverArgv(task: string, summary: string, wake: string): string[] {
  return ["append", "--task", task, "--verdict", "captain", "--summary", summary, "--silent", "false", "--wake", wake];
}

/** The bounded evidence copy a record stores: the whole bundle when it fits
 * the cap, otherwise exactly the first and last half of the cap with the
 * middle omitted, so neither end of a long bundle is lost. */
export function captureEvidenceCopy(text: string): { text: string; len: number } {
  if (text.length <= CLASSIFIER_EVIDENCE_TEXT_CAP) return { text, len: text.length };
  const half = CLASSIFIER_EVIDENCE_TEXT_CAP / 2;
  return { text: text.slice(0, half) + text.slice(text.length - half), len: text.length };
}

/** The durable classification-log record, field order pinned: the scorers
 * (bin/fm-branch-classifier-score.sh) parse it, and byte-stability keeps the
 * log diffable across refactors. */
export function buildClassifierRecord(input: {
  clock: { iso(): string };
  wake: string;
  tasks: string[];
  seqs: string[];
  evidence: ClassifierEvidence[];
  result: ClassifierResult;
}): ClassifierRecord {
  return {
    t: input.clock.iso(),
    wake: input.wake,
    tasks: input.tasks,
    seqs: input.seqs,
    evidence: input.evidence.map((b) => {
      const copy = captureEvidenceCopy(b.text);
      return { task: b.task, from: b.from, to: b.to, text: copy.text, text_len: copy.len };
    }),
    text_cap: CLASSIFIER_EVIDENCE_TEXT_CAP,
    verdict: input.result.verdict,
    reason: input.result.reason,
    model: input.result.model,
    ms: input.result.ms,
    answer: input.result.answer,
  };
}

/** One JSON line plus newline, ready for the host's size-capped append. */
export function serializeClassifierRecord(record: ClassifierRecord): string {
  return `${JSON.stringify(record)}\n`;
}

// ---- The deterministic verb route -----------------------------------------
//
// The recognised-verb vocabulary is mirrored from its one owner,
// bin/fm-classify-lib.sh: the terminal captain verbs of
// status_is_captain_relevant (done, needs-decision, blocked, failed) and the
// nonterminal verbs it reads as routine (working, resolved, captain-held,
// paused). Within that set a line is captain-relevant exactly when its verb
// is terminal, so the route never needs the lib's legacy free-text fallback -
// and deliberately never applies it: a line without a recognised verb (a
// note: line, a bare legacy token such as "merged", continuation prose) is
// unrecognised content that keeps the model path, per the replay evidence
// that a note: line can carry a captain ask the verb whitelist cannot see.
// The lib's per-home verb overrides (FM_CAPTAIN_RE and friends) are out of
// scope for a host-agnostic module; a home running a custom vocabulary
// simply keeps the model path, which is today's behavior.

const CLASSIFIER_TERMINAL_VERBS = new Set(["done", "needs-decision", "blocked", "failed"]);
const CLASSIFIER_ROUTINE_VERBS = new Set(["working", "resolved", "captain-held", "paused"]);
const CLASSIFIER_DETERMINISTIC_REASON = "deterministic verb route";

/** The leading verb of one status line, byte-faithful to
 * bin/fm-classify-lib.sh status_line_verb: the text before the first colon,
 * cut at the first "[", trimmed, with correlation tokens dropped so a
 * "done [at=..] [key=..]:" or "done corr=<hex>:" line keeps its verb. */
function statusLineVerb(line: string): string {
  const colon = line.indexOf(":");
  let v = colon >= 0 ? line.slice(0, colon) : line;
  const bracket = v.indexOf("[");
  if (bracket >= 0) v = v.slice(0, bracket);
  v = v.trim();
  if (v.includes("corr=")) {
    const words = v.split(/\s+/).filter((w) => w !== "");
    v = words.filter((w, i) => i === 0 || !/^corr=[0-9a-fA-F]{16}$/.test(w)).join(" ");
  }
  return v;
}

/** The NEW status lines one well-formed evidence bundle judges: the section
 * between the gatherer's NEW and HISTORY markers with the gatherer's
 * two-space line indent removed, blank lines and the gatherer's "(none"
 * zero-new marker dropped. The HISTORY marker is matched mid-line, because
 * the 6,000-byte NEW-block cap can fuse it onto the tail of the last partial
 * line the classifier saw; that head is a NEW line and is judged. Returns
 * null only for a bundle with no status byte range - a failed or unparseable
 * gather whose failure text is model evidence, never route input. */
function classifierNewStatusLines(bundle: ClassifierEvidence): string[] | null {
  if (bundle.from < 0 || bundle.to < 0) return null;
  const out: string[] = [];
  let inNew = false;
  for (const line of bundle.text.split("\n")) {
    if (line.includes("## status lines appended since the last classified wake")) {
      inNew = true;
      continue;
    }
    const hist = line.indexOf("## earlier lines, already handled by earlier wakes");
    if (hist >= 0) {
      if (inNew) {
        const head = line.slice(0, hist).replace(/^ {2}/, "");
        if (head.trim() !== "" && !head.startsWith("(none")) out.push(head);
      }
      inNew = false;
      continue;
    }
    if (!inNew) continue;
    const s = line.replace(/^ {2}/, "");
    if (s.trim() === "" || s.startsWith("(none")) continue;
    out.push(s);
  }
  return out;
}

/** The deterministic verb route: the verdict code can emit when every NEW
 * status line in every gathered bundle carries a recognised verb and at
 * least one line exists - captain when any line's verb is terminal, routine
 * otherwise. Null keeps the model path: any unrecognised line, a failed or
 * unparseable gather, or zero new bytes is evidence a model must judge,
 * exactly as it always has. Replay evidence (131 recorded classification
 * calls): 110 of 131 fall in this class, the exact-verb route matched the
 * recorded label on all of them, and the model call it replaces was wrong
 * on 13 of the 131. */
function deterministicVerbRoute(evidence: ClassifierEvidence[]): { verdict: string; reason: string } | null {
  let any = false;
  let captain = false;
  for (const bundle of evidence) {
    const lines = classifierNewStatusLines(bundle);
    if (lines === null) return null;
    for (const line of lines) {
      any = true;
      const verb = statusLineVerb(line);
      if (CLASSIFIER_TERMINAL_VERBS.has(verb)) captain = true;
      else if (!CLASSIFIER_ROUTINE_VERBS.has(verb)) return null;
    }
  }
  if (!any) return null;
  return { verdict: captain ? "captain" : "routine", reason: CLASSIFIER_DETERMINISTIC_REASON };
}

export interface ClassifyOutcome {
  result: ClassifierResult;
  record: ClassifierRecord;
  recordLine: string;
}

/** The classifier ahead of the branch: gather each task's evidence bundle,
 * ask the configured model, and return the verdict plus the exact durable
 * record. The host appends recordLine to its classification log. */
export async function classifyWake(deps: ClassifierDeps, input: { wake: string; tasks: string[]; seqs: string[] }): Promise<ClassifyOutcome> {
  const system = await classifierSystemPrompt(deps);
  const evidence: ClassifierEvidence[] = [];
  for (const task of input.tasks) evidence.push(await gatherClassifierEvidence(deps, task));
  const prompt = buildClassifierPrompt(input.wake, evidence);
  // The deterministic verb route sits between the evidence and the model:
  // the gathers above already advanced the classifier offset and fed the
  // covering-outcome rule exactly as on any wake, so only the completion
  // call is ever skipped, and the record keeps its exact shape with the
  // model recorded as null (the scorer reads a null model as "unknown").
  const routed = deterministicVerbRoute(evidence);
  // Which model to call is resolved here, once, before any completion call:
  // the explicit configured name wins, otherwise the host's own default. A
  // host that can resolve neither records the failed call without a
  // completion attempt.
  const model = routed ? null : (await deps.readConfiguredModel()) || (await deps.readDefaultModel());
  const t0 = deps.clock.now();
  if (routed) {
    const result: ClassifierResult = {
      verdict: routed.verdict,
      reason: routed.reason,
      ms: deps.clock.now() - t0,
      promptChars: prompt.length + system.length,
      answer: "",
      model: null,
      evidence,
    };
    const record = buildClassifierRecord({ clock: deps.clock, wake: input.wake, tasks: input.tasks, seqs: input.seqs, evidence, result });
    return { result, record, recordLine: serializeClassifierRecord(record) };
  }
  let answer = "";
  let usedModel = model;
  let completeError: string | null = null;
  if (model) {
    try {
      answer = String(await deps.complete({ model, system, prompt, maxTokens: CLASSIFIER_MAX_TOKENS }));
    } catch (error) {
      completeError = String(error);
      if (isClassifierModelNotFoundError(completeError)) {
        // The one-shot model-not-found fallback, owned here so both hosts
        // behave identically: retry the same request once on the host's
        // default. A missing or failed default read, a default equal to the
        // requested name, and a failed retry all leave today's failed-call
        // surface, and the record carries the model actually used.
        let fallback: string | null = null;
        try {
          fallback = await deps.readDefaultModel();
        } catch {
          fallback = null;
        }
        if (fallback && fallback !== model) {
          usedModel = fallback;
          try {
            answer = String(await deps.complete({ model: fallback, system, prompt, maxTokens: CLASSIFIER_MAX_TOKENS }));
            completeError = null;
          } catch (retryError) {
            completeError = String(retryError);
          }
        }
      }
    }
  } else {
    completeError = "no classifier model resolved on this host";
  }
  const parsed = interpretClassifierAnswer(answer, completeError);
  const result: ClassifierResult = {
    verdict: parsed.verdict,
    reason: parsed.reason,
    ms: deps.clock.now() - t0,
    promptChars: prompt.length + system.length,
    answer: answer.slice(0, CLASSIFIER_ANSWER_CAP),
    model: usedModel,
    evidence,
  };
  const record = buildClassifierRecord({ clock: deps.clock, wake: input.wake, tasks: input.tasks, seqs: input.seqs, evidence, result });
  return { result, record, recordLine: serializeClassifierRecord(record) };
}
