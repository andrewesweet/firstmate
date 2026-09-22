// One owner for the supervision-branch shadow-advisory trial core, shared by
// the Pi supervision-branch extension (.pi/extensions/fm-branch-supervision.ts)
// and the Claude Code supervision-branch mod
// (.claude/mods/fm-branch-mod/hooks/branch.ts).
//
// This module owns, once: the evidence-bundle parsers (per-task fresh status
// lines with byte ids, the bounded current-state extract, the owner/repo#N PR
// identity rule), the detached trial's question bundle (route, phase,
// severity, no-new-outcome on every wake; stale-state only on stale wakes;
// per-candidate Nouls with provenance on compound wakes), the deterministic
// facts object the candidate gates (bin/fm-branch-shadow-gates.sh) score,
// state assembly (unread status lines, prior outcomes with provenance, open
// captain calls, bounded pane evidence), the ablation variant set with its
// repeat control, the answer-call and pane-helper output parsing, the durable
// shadow-log record shape and its serialization, and the candidate-Noul
// extraction that folds a record's own answers back into its facts.
//
// Byte-stability contracts this module must never break: the facts object and
// the record shape are read by bin/fm-branch-shadow-score.sh and
// bin/fm-branch-shadow-gates.sh, and the wake key the record carries must
// stay the same "epoch:seq" set the granted wake's outcome row stamps (the
// join never depends on agent-supplied wake text).
//
// Host seams - declared, deliberately not unified:
//   - SCRIPT SPAWNS. The host binds cwd and environment; this module builds
//     the argv for bin/fm-branch-shadow-pane.sh and bin/fm-branch-shadow-jev.sh
//     and owns their timeouts. The API key lives only inside the bash helper.
//   - FILE READS AND APPENDS. The host reads state records (outcome index,
//     status logs, cursor, outcome store) and appends the serialized record
//     line to state/branch-mod-shadow.jsonl with its own rotation and
//     failure logging.
//   - ERROR NOTIFICATIONS. The mod logs both failure kinds into its event
//     log; the Pi extension drops them silently - the trial is detached and
//     per-call failures are already durable as unavailable records.
//   - THE OPEN-CALL RULE. Each host binds the shared eligibility fold
//     (hasOpenNeedsDecision) to its own status reads; this module owns only
//     the loop shape and the {task} entry shape.
//   - THE CLOCK is injected, so tests pin record bytes without waiting.
//
// The mod loads this file directly from its own lib/ directory; the repo's
// lib/ entry is a tracked symlink to it (the Calm-mod pattern, inverted
// because a hooks module may import only its own files, never across the
// mod boundary). This file must therefore stay dependency-free: no imports
// of any kind.

export interface ShadowEvidence {
  task: string;
  from: number;
  to: number;
  text: string;
}

export type ShadowState = Record<string, unknown>;

/** The helper's window identity and stale-series markers, folded into local
 * facts only - the request's pane payload keeps exactly the fields it has
 * always carried. */
export interface ShadowPaneExtras {
  window?: string;
  stale?: { series_index?: number; wedge_escalations?: number };
}

export type ShadowFacts = {
  wake_key: string;
  new_status_bytes: Record<string, number>;
  pane?: string;
  stale_series?: { series_index?: number; wedge_escalations?: number };
  pane_observation?: Record<string, unknown>;
  authoritative_pr: { present: boolean; pr?: string };
  severity_classes: string[];
  candidates?: Record<string, number>;
};

export const SHADOW_TIMEOUT_MS = 10_000;
export const SHADOW_PANE_TIMEOUT_MS = 6_000;
/** Every Nth wake runs the full variant twice, measuring raw call noise. */
export const SHADOW_CONTROL_EVERY = 10;
export const SHADOW_LINES_PER_TASK = 12;
export const SHADOW_PRIOR_PER_TASK = 4;
export const SHADOW_MODEL = "jev-latest";
/** Prefix flattening each compound-wake candidate into its own top-level
 * typed question (`candidate:<task-id>`): the questions map accepts only
 * typed questions, so a nested `candidates` entry is rejected (HTTP 422).
 * The API names each key freely (https://docs.typesafe.ai/api: "A key you
 * choose"), so the colon separator is safe next to hyphen-and-digit task
 * ids; stripping this prefix reverses the fold, and both the request
 * builder and the answer reader below share this one constant. */
export const SHADOW_CANDIDATE_PREFIX = "candidate:";
/** Policy floors written into every record: Choice confidence floor; a Noul
 * below the grant floor is a grant, above the pass floor a pass. */
export const SHADOW_POLICY = { choice_confidence_floor: 0.85, noul_grant_below: 0.15, noul_pass_above: 0.85 };

/** UTF-8 byte length, the id and requestBytes unit throughout this module. */
export function utf8ByteLen(s: string): number {
  return new TextEncoder().encode(s).length;
}

/** The fresh status lines of one evidence bundle, each id carrying the
 * line's status-log byte range (multibyte-safe: ids are byte offsets). */
export function shadowStatusLines(task: string, from: number, to: number, text: string): Array<{ id: string; text: string }> {
  const out: Array<{ id: string; text: string }> = [];
  let inside = false;
  let byte = from;
  for (const line of text.split("\n")) {
    if (line.startsWith("## ")) {
      inside = line.startsWith("## status lines appended");
      continue;
    }
    if (!inside || !line.trim()) continue;
    const content = line.replace(/^  /, "");
    if (!content || content.startsWith("(none")) continue;
    const len = utf8ByteLen(content);
    out.push({ id: `${task}:${byte}-${Math.min(byte + len, to)}`, text: content });
    byte += len + 1;
  }
  return out;
}

/** The bounded current-state extract of one evidence bundle; empty when the
 * bundle names no state or names a failed gatherer. */
export function shadowCurrentState(task: string, text: string): string {
  const lines = text.split("\n");
  const at = lines.findIndex((l) => l.startsWith("## current state"));
  if (at < 0) return "";
  const body: string[] = [];
  for (let k = at + 1; k < lines.length && !lines[k].startsWith("## "); k++) body.push(lines[k]);
  const s = body.join("\n").trim();
  return s && !s.startsWith("(evidence gatherer failed") ? s.slice(0, 1500) : "";
}

/** owner/repo#number from a pull-request URL; empty when the URL is not one. */
export function prIdentity(url: string): string {
  const m = String(url).match(/^https:\/\/[^/]+\/(.+)\/pull\/([0-9]+)\/?$/);
  if (!m) return "";
  const segs = m[1].split("/");
  if (segs.length < 2) return "";
  return `${segs[segs.length - 2]}/${segs[segs.length - 1]}#${m[2]}`;
}

/** The authoritative PR sources carried by the evidence bundles: pull-request
 * URLs in task order, deduplicated, bounded at eight. */
export function prSourcesFromEvidence(evidence: ShadowEvidence[]): Array<{ task: string; where: string; value: string }> {
  const prSources: Array<{ task: string; where: string; value: string }> = [];
  for (const b of evidence) {
    for (const m of String(b.text).matchAll(/https:\/\/[^\s)"']+/g)) {
      if (/\/pull\/[0-9]+/.test(m[0]) && !prSources.some((p) => p.value === m[0]) && prSources.length < 8) {
        prSources.push({ task: b.task, where: "status", value: m[0] });
      }
    }
  }
  return prSources;
}

/** The endpoint byte of one task's outcome index record (0 when the record
 * is absent, torn, or names no parseable endpoint). */
export function outcomeIndexEndpoint(indexText: string): number {
  const idx = indexText.split("\t");
  return idx[0] === "fm-branch-outcome-index-v1" && /^[0-9]+$/.test(idx[2] ?? "") ? Number(idx[2]) : 0;
}

/** The unread status lines of one task from its last outcome endpoint, each
 * id carrying the line's status-log byte range. */
export function unreadStatusLinesFrom(task: string, endpoint: number, text: string): Array<{ id: string; text: string }> {
  const out: Array<{ id: string; text: string }> = [];
  let byte = endpoint;
  for (const line of text.slice(endpoint).split("\n")) {
    const len = utf8ByteLen(line);
    if (line.trim()) out.push({ id: `${task}:${byte}-${byte + len}`, text: line });
    byte += len + 1;
  }
  return out;
}

/** One prior-outcome row's provenance entry: whether the same wake produced
 * it, whether main has already seen it, and whether it came from a
 * classifier pass rather than an accepted branch report. */
export function priorOutcomeEntry(task: string, r: Record<string, unknown>, wake: string, readThrough: number): Record<string, unknown> {
  const seq = Number(r.seq) || 0;
  const summary = String(r.summary ?? "");
  return {
    task,
    seq,
    verdict: String(r.verdict ?? ""),
    summary: summary.slice(0, 300),
    source: /^Passed to main directly \((classifier|scope unsafe)/.test(summary) ? "classifier_pass" : "accepted_branch",
    same_wake: String(r.wake ?? "") === wake,
    already_presented: readThrough >= 0 && seq <= readThrough,
  };
}

/** The question bundle: route/phase/severity/no-new-outcome on every wake,
 * stale-state only on stale wakes, per-candidate Nouls with provenance on
 * compound wakes. The recovery question from the phase-1 survey is dropped. */
export function buildShadowQuestions(a: { wake: string; tasks: string[] }, st: ShadowState): Record<string, unknown> {
  const questions: Record<string, unknown> = {
    route: {
      type: "choice",
      instructions:
        "Which route is required after this wake is handled? Judge only fresh or unread evidence and the observed action result; conservative routing means anything uncertain routes to the captain.",
      criteria: {
        routine: "No new requested result, review item, human-only decision, surviving blocker, credential need, or security/destructive impact.",
        main: "A requested result is finished, review is ready, a new human-only decision or surviving blocker/failure exists, or a credential/login is needed, or the impact is security-, privacy-, data-loss-, or externally-visible.",
      },
    },
    phase: {
      type: "choice",
      instructions: "Which phase best describes the authoritative current evidence?",
      criteria: {
        no_change: "No new state beyond a signal or history",
        working: "Started, implementing, or validating normally",
        waiting: "A declared external wait or routine confirmation",
        finished_ready: "A requested result or review artifact is ready",
        blocked_failed: "Work cannot continue or recovery failed",
        unknown: "Evidence is contradictory, missing, or unreadable",
      },
    },
    severity: {
      type: "score",
      instructions: "How severe is the observed condition after available recovery evidence?",
      criteria: [
        "False alarm or no functional impact",
        "Routine recoverable interruption or non-blocking failure",
        "Task blocked or failed after normal recovery",
        "Security, privacy, data-loss, irreversible, credential, or external-publication impact",
      ],
    },
    no_new_outcome: {
      type: "noul",
      instructions: "Can this wake be treated as carrying no new outcome beyond prior_outcomes?",
      criteria: {
        true: "Only signal, history, or unchanged facts are present",
        false: "A fresh fact changes phase, artifact, an open call, a blocker, or the required action",
      },
    },
  };
  if (/^stale:/m.test(a.wake)) {
    questions.stale_state = {
      type: "choice",
      instructions: "Given the current-state and pane evidence rather than the stale header alone, which state is the worker in?",
      criteria: {
        active: "The worker is running or thinking normally",
        expected_external_wait: "A declared external wait the worker chose",
        routine_confirmation_wait: "Parked on a routine confirmation it already selected",
        finished_ready: "Its requested result or review artifact is ready",
        stuck_or_looping: "Repeated identical output or no progress",
        dead_or_unreadable: "The endpoint is gone or unreadable",
        unknown: "Evidence is contradictory or missing",
      },
    };
  }
  if (a.tasks.length > 1) {
    const prior = (st.prior_outcomes as Array<Record<string, unknown>> | undefined) ?? [];
    const fresh = (st.fresh_status as Array<{ id: string; text: string }> | undefined) ?? [];
    for (const t of a.tasks) {
      questions[`${SHADOW_CANDIDATE_PREFIX}${t}`] = {
        type: "noul",
        instructions: {
          question: "Is this candidate a still-unreported actionable fact in this wake?",
          candidate: t,
          fresh_lines: fresh.filter((f) => f.id.startsWith(`${t}:`)),
          prior_outcome: prior.filter((p) => p.task === t).at(-1) ?? null,
        },
        criteria: {
          true: "A new fact that changes the artifact, phase, an open call, a blocker, or the required action",
          false: "History, a duplicate, continuation prose, or a superseded fact",
        },
      };
    }
  }
  return questions;
}

/** The wake's facts, minus the per-variant candidates that only the answer
 * can supply (the record builder merges those from each record's own
 * answers). Facts come only from state the host already assembled - never a
 * second read, never an invented value. */
export function buildShadowFacts(
  a: { wakeKey: string; tasks: string[]; evidence: ShadowEvidence[] },
  st: ShadowState,
  paneExtras: ShadowPaneExtras | null,
  questions: Record<string, unknown>,
): ShadowFacts {
  const facts: ShadowFacts = { wake_key: a.wakeKey, new_status_bytes: {}, authoritative_pr: { present: false }, severity_classes: [] };
  for (const b of a.evidence) if (b.from >= 0 && b.to >= b.from) facts.new_status_bytes[b.task] = b.to - b.from;
  if (paneExtras?.window) facts.pane = paneExtras.window;
  if (paneExtras?.stale) facts.stale_series = paneExtras.stale;
  const obs = st.pane ? (st.pane as Record<string, unknown>).observation : undefined;
  if (obs && typeof obs === "object") facts.pane_observation = obs as Record<string, unknown>;
  const sources = (st.authoritative_pr_sources ?? []) as Array<{ value: string }>;
  facts.authoritative_pr = { present: sources.length > 0 };
  for (const s of sources) {
    const id = prIdentity(s.value);
    if (id) {
      facts.authoritative_pr.pr = id;
      break;
    }
  }
  const sev = questions.severity as { criteria?: unknown } | undefined;
  if (sev && Array.isArray(sev.criteria)) facts.severity_classes = sev.criteria.map((c) => String(c));
  return facts;
}

export interface ShadowVariant {
  name: string;
  drop: string[];
  repeat: number;
}

/** The ablation variants of one wake: the full bundle, one without current
 * state, prior outcomes, or pane tail, plus the repeat control on every
 * SHADOW_CONTROL_EVERYth wake. */
export function shadowVariants(wakeNo: number): ShadowVariant[] {
  const variants: ShadowVariant[] = [
    { name: "full", drop: [], repeat: 1 },
    { name: "without_current_state", drop: ["current_state"], repeat: 1 },
    { name: "without_prior_outcomes", drop: ["prior_outcomes"], repeat: 1 },
    { name: "without_pane_tail", drop: ["pane"], repeat: 1 },
  ];
  if (wakeNo % SHADOW_CONTROL_EVERY === 0) variants.push({ name: "full", drop: [], repeat: 2 });
  return variants;
}

/** One variant's request state: the assembled state minus the dropped keys. */
export function applyShadowVariant(st: ShadowState, drop: string[]): ShadowState {
  const state: ShadowState = {};
  for (const [k, val] of Object.entries(st)) if (!drop.includes(k)) state[k] = val;
  return state;
}

/** The answer-call request body: model, state, questions - byte-stable. */
export function buildShadowRequest(state: ShadowState, questions: Record<string, unknown>): string {
  return JSON.stringify({ model: SHADOW_MODEL, state, questions });
}

/** The last JSON-looking line of a helper's stdout, or null when there is
 * none. JSON.parse of the returned line is the caller's job, so a malformed
 * line keeps each caller's own failure shape. */
export function pickJsonLine(stdout: string): string | null {
  return (
    stdout
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("{"))
      .pop() ?? null
  );
}

/** The candidate Nouls a record's own answers supply, keyed by task id:
 * the flattened `candidate:<task>` top-level answers, plus the pre-fix
 * nested `answers.candidates` object so old log lines still fold. */
export function candidateNouls(answers: unknown): Record<string, number> {
  const cands: Record<string, number> = {};
  const ans = ((answers ?? {}) as Record<string, unknown>);
  for (const [key, c] of Object.entries(ans)) {
    if (!key.startsWith(SHADOW_CANDIDATE_PREFIX)) continue;
    if (c && typeof (c as Record<string, unknown>).noul === "number") cands[key.slice(SHADOW_CANDIDATE_PREFIX.length)] = (c as Record<string, number>).noul;
  }
  const legacy = ans.candidates;
  if (legacy && typeof legacy === "object") {
    for (const [tid, c] of Object.entries(legacy as Record<string, unknown>)) {
      if (!(tid in cands) && c && typeof (c as Record<string, unknown>).noul === "number") cands[tid] = (c as Record<string, number>).noul;
    }
  }
  return cands;
}

export interface ShadowRecordInput {
  clock: { iso(): string };
  wake: string;
  seqs: string[];
  wakeKey: string;
  tasks: string[];
  wakeNo: number;
  variant: string;
  repeat: number;
  body: string;
  unavailable: string | null;
  model: string;
  answers: unknown;
  /** The helper call's measured duration, milliseconds. */
  ms: number;
  facts: ShadowFacts;
}

/** The durable shadow-log record, field order pinned: the scorers
 * (bin/fm-branch-shadow-score.sh, bin/fm-branch-shadow-gates.sh) parse it and
 * join it to the outcome store by wakeKey. A successful answer folds the
 * record's own candidate Nouls into a copied facts object, so each variant's
 * facts carry what that variant actually said and no caller's facts object is
 * mutated across variants. */
export function buildShadowRecord(input: ShadowRecordInput): Record<string, unknown> {
  let facts = input.facts;
  const record: Record<string, unknown> = {
    t: input.clock.iso(),
    kind: "shadow",
    wake: input.wake,
    seqs: input.seqs,
    wakeKey: input.wakeKey,
    tasks: input.tasks,
    wakeNo: input.wakeNo,
    variant: input.variant,
    repeat: input.repeat,
    control: input.repeat > 1,
    unavailable: input.unavailable,
    requestBytes: utf8ByteLen(input.body),
    ms: input.ms,
    policy: { choice_confidence_floor: SHADOW_POLICY.choice_confidence_floor, noul_grant_below: SHADOW_POLICY.noul_grant_below, noul_pass_above: SHADOW_POLICY.noul_pass_above },
  };
  if (input.answers !== null) {
    record.model = input.model;
    record.answers = input.answers;
    // Candidate Nouls from this record's own answers, so each variant's facts
    // carry what that variant actually said.
    const cands = candidateNouls(input.answers);
    if (Object.keys(cands).length) facts = { ...facts, candidates: cands };
  }
  record.facts = facts;
  return record;
}

/** One JSON line plus newline, ready for the host's size-capped append. */
export function serializeShadowRecord(record: Record<string, unknown>): string {
  return `${JSON.stringify(record)}\n`;
}

/** The host surface the shadow trial runs against. runScript binds the
 * host's cwd and environment; readFile rejects on an absent or unreadable
 * path; hasOpenCall binds the shared eligibility fold to the host's own
 * status reads and returns false whenever it cannot prove an open call. */
export interface ShadowDeps {
  paths: { bin: string; state: string };
  readFile(path: string): Promise<string>;
  hasOpenCall(task: string): Promise<boolean>;
  runScript(argv: string[], opts: { timeoutMs: number; stdin?: string }): Promise<{ exitCode: number; stdout: string; stderr: string }>;
  readConfig(name: string, fallback: string): Promise<string>;
  appendShadowRecord(line: string): Promise<void>;
  onShadowError(kind: "shadow.error" | "shadow.log.error", error: unknown): void;
  clock: { now(): number; iso(): string };
}

/** The wake state the host already holds, assembled read-only with the same
 * bounds the branch note and the classifier use. Fields with no evidence are
 * omitted entirely, never invented. Key insertion order is part of the
 * byte-stability contract: wake, fresh_status, current_state, unread_status,
 * authoritative_pr_sources, prior_outcomes, open_calls, pane. */
async function assembleShadowState(
  deps: ShadowDeps,
  a: { wake: string; tasks: string[]; evidence: ShadowEvidence[] },
): Promise<{ st: ShadowState; paneExtras: ShadowPaneExtras | null }> {
  const st: ShadowState = { wake: a.wake };
  const fresh: Array<{ id: string; text: string }> = [];
  const currentState: Array<{ task: string; value: string }> = [];
  for (const b of a.evidence) {
    fresh.push(...shadowStatusLines(b.task, b.from, b.to, b.text));
    const cs = shadowCurrentState(b.task, b.text);
    if (cs) currentState.push({ task: b.task, value: cs });
  }
  const prSources = prSourcesFromEvidence(a.evidence);
  st.fresh_status = fresh.slice(-SHADOW_LINES_PER_TASK * Math.max(a.tasks.length, 1));
  if (currentState.length) st.current_state = currentState;
  // Unread lines: appended since the task's last outcome, the branch note's own bound.
  const unread: Array<{ id: string; text: string }> = [];
  for (const task of a.tasks) {
    let endpoint = 0;
    try {
      endpoint = outcomeIndexEndpoint(await deps.readFile(`${deps.paths.state}/.${task}.branch-outcome-index`));
    } catch {
      endpoint = 0;
    }
    let text = "";
    try {
      text = await deps.readFile(`${deps.paths.state}/${task}.status`);
    } catch {
      text = "";
    }
    unread.push(...unreadStatusLinesFrom(task, endpoint, text));
  }
  st.unread_status = unread.slice(-SHADOW_LINES_PER_TASK * Math.max(a.tasks.length, 1));
  if (prSources.length) st.authoritative_pr_sources = prSources;
  // Prior outcomes with provenance (phase-1 policy).
  let readThrough = -1;
  try {
    const n = Number((await deps.readFile(`${deps.paths.state}/.branch-outcomes-cursor`)).trim());
    readThrough = Number.isFinite(n) ? n : -1;
  } catch {
    readThrough = -1;
  }
  let rows: Array<Record<string, unknown>> = [];
  try {
    rows = (await deps.readFile(`${deps.paths.state}/branch-outcomes.jsonl`))
      .split("\n")
      .filter((l) => l.trim())
      .map((l) => {
        try {
          return JSON.parse(l) as Record<string, unknown>;
        } catch {
          return null;
        }
      })
      .filter((r) => r !== null);
  } catch {
    rows = [];
  }
  const prior: Array<Record<string, unknown>> = [];
  for (const task of a.tasks) {
    for (const r of rows.filter((r) => r.task === task).slice(-SHADOW_PRIOR_PER_TASK)) {
      prior.push(priorOutcomeEntry(task, r, a.wake, readThrough));
    }
  }
  if (prior.length) st.prior_outcomes = prior;
  // Open captain calls, from the shared fold through the host's binding.
  const openCalls: Array<{ task: string }> = [];
  for (const task of a.tasks) {
    if (await deps.hasOpenCall(task)) openCalls.push({ task });
  }
  if (openCalls.length) st.open_calls = openCalls;
  // Bounded pane evidence for the first eligible task, through the helper.
  let paneExtras: ShadowPaneExtras | null = null;
  try {
    const r = await deps.runScript(["bash", `${deps.paths.bin}/fm-branch-shadow-pane.sh`, a.tasks[0]], {
      timeoutMs: SHADOW_PANE_TIMEOUT_MS,
    });
    const line = pickJsonLine(r.stdout);
    const j = line ? JSON.parse(line) : null;
    if (j && !j.unavailable) {
      // The request keeps carrying exactly the pane fields it always has;
      // the helper's window identity and stale series feed local facts only.
      if (j.tail || j.observation)
        st.pane = { task: j.task, ...(j.tail ? { tail: j.tail } : {}), ...(j.observation ? { observation: j.observation } : {}) };
      paneExtras = { ...(j.window ? { window: String(j.window) } : {}), ...(j.stale ? { stale: j.stale } : {}) };
    }
  } catch {
    // no pane evidence: the field stays absent
  }
  return { st, paneExtras };
}

/** One answer call and its durable record. A slow, failed, or malformed
 * answer becomes an unavailable record; nothing here throws past the trial. */
async function runShadowRecord(
  deps: ShadowDeps,
  a: { wake: string; seqs: string[]; wakeKey: string; tasks: string[]; wakeNo: number },
  variant: string,
  repeat: number,
  body: string,
  facts: ShadowFacts,
): Promise<void> {
  const t0 = deps.clock.now();
  let unavailable: string | null = null;
  let model = "";
  let answers: unknown = null;
  try {
    const r = await deps.runScript(["bash", `${deps.paths.bin}/fm-branch-shadow-jev.sh`], {
      timeoutMs: SHADOW_TIMEOUT_MS,
      stdin: body,
    });
    const line = pickJsonLine(r.stdout);
    const j = line ? JSON.parse(line) : null;
    if (j && j.ok === true) {
      model = String(j.model ?? "jev");
      answers = j.answers;
    } else unavailable = String((j && j.unavailable) || "unavailable").slice(0, 200);
  } catch (error) {
    unavailable = `helper failed: ${String(error)}`.slice(0, 200);
  }
  const record = buildShadowRecord({
    clock: deps.clock,
    wake: a.wake,
    seqs: a.seqs,
    wakeKey: a.wakeKey,
    tasks: a.tasks,
    wakeNo: a.wakeNo,
    variant,
    repeat,
    body,
    unavailable,
    model,
    answers,
    ms: deps.clock.now() - t0,
    facts,
  });
  try {
    await deps.appendShadowRecord(serializeShadowRecord(record));
  } catch (error) {
    deps.onShadowError("shadow.log.error", error);
  }
}

/** The detached trial itself: config-gated (classifier-shadow = jev),
 * read-only, fully fire-and-forget. It must never delay or alter the wake:
 * every failure is recorded or notified, never thrown. */
export async function runShadowAdvisory(
  deps: ShadowDeps,
  a: { wake: string; seqs: string[]; wakeKey: string; tasks: string[]; evidence: ShadowEvidence[]; wakeNo: number },
): Promise<void> {
  try {
    if ((await deps.readConfig("classifier-shadow", "")).trim() !== "jev") return;
    const { st, paneExtras } = await assembleShadowState(deps, a);
    const questions = buildShadowQuestions(a, st);
    const facts = buildShadowFacts(a, st, paneExtras, questions);
    for (const v of shadowVariants(a.wakeNo)) {
      const state = applyShadowVariant(st, v.drop);
      await runShadowRecord(deps, a, v.name, v.repeat, buildShadowRequest(state, questions), { ...facts });
    }
  } catch (error) {
    deps.onShadowError("shadow.error", error);
  }
}
