// Shared wake-eligibility and status-decision fold for the supervision
// branch's TypeScript ports (docs/pi-supervision-branch.md,
// docs/claude-supervision-branch.md). This module is the one owner of the
// fold that the repo previously carried three times: the authoritative bash
// fold (bin/fm-classify-lib.sh `status_open_decisions`, fold version 9), the
// Pi extension's `scopeForUnreadWake`
// (.pi/extensions/lib/fm-branch-dispatch.ts, which now delegates here), and
// the Claude mod's port (.claude/mods/fm-branch-mod/hooks/branch.ts, still
// inline). tests/fm-branch-eligibility.test.sh pins this module against the
// bash fold on one fixture set, so wherever this file and bash disagree, the
// test fails.
//
// Behaviour is bash v9 truth wherever bin/fm-classify-lib.sh has an opinion.
// Each rule below names the bash fold version that introduced it.
// Where bash has none, this module takes the stricter of the two ports and
// records the choice here, one line per choice:
//   - Fold vocabulary: bash's names and defaults exactly - the resolve verb
//     (FM_CLASSIFY_RESOLVE_VERB, default `resolved`), the durable
//     captain-held transfer verb (FM_CLASSIFY_CAPTAIN_HELD_VERB, default
//     `captain-held`), the reserved decision-key prefixes
//     (FM_CLASSIFY_RESERVED_KEY_PREFIXES, default `pending-reply-`), and the
//     pause verb the event vocabulary needs (FM_CLASSIFY_PAUSED_VERB,
//     default `paused`).
//   - Time tags (bash v9): every head/note question - the declaration
//     guard, the terminal-close colon test, the key reader, the note reader -
//     reads the line with its `[at=...]` stamp stripped
//     (statusLineUnstamped), so a readable worker stamp cannot move the
//     separator. The stored bytes stay the writer's own.
//   - Terminal close (bash v8): a `done:`/`failed:` declaration closes the
//     WHOLE open set when the task's kind is ship or scout; a secondmate's
//     terminal event may describe other work and closes nothing.
//   - Symlinked or unreadable status log: bash's outcome - that task's fold
//     is empty, never a scan refusal. (The mod reads through the link; that
//     drift is asserted in tests/fm-branch-eligibility.test.sh until the mod
//     adopts this rule.)
//   - Symlinked, missing, or unreadable task meta: bash's rule - the kind is
//     `unknown`, so the terminal close never applies; a readable meta
//     silent about `kind=` means `ship`.
//   - Torn queue row: the mod's rule (the stricter port) - the epoch field
//     and the seq field must each be purely numeric or the scan refuses as
//     corrupt.
//   - Stale-read hygiene: Pi's file-version cache kept - a verdict is
//     cached per task keyed on the stat version and the fold configuration,
//     evicted past 512 entries, and a stat version that changed between the
//     stat and the read refuses the scan (the mod has no check).
//   - Wake identity: the mod's derivation - `<epoch>:<seq>` per claimed row,
//     comma-joined.
//   - Line splitting: bash's `read -r` - a log or meta splits on `\n` alone,
//     so a trailing `\r` stays on the line (a `kind=ship\r` meta is
//     `unknown`, a note keeps its `\r`). The mod splits on `\r?\n`.
//   - Captain-held declaration check: bash's event scan (the mod's
//     `lastStatusLine` ports it) - the last RECOGNIZED event's verb must be
//     the held verb, falling back to the
//     last non-blank line only when the log holds no event at all. The
//     legacy captain-token fallback regex is bash's default; bash's inline
//     FM_CAPTAIN_RE override is not carried (no TS consumer reads it).
//
// The core is pure: every file touch is an injected input, so each consumer
// binds its own file access and tests/fm-branch-eligibility.test.sh drives
// this module through the same fixtures as the implementations it replaces.
// The repo's lib/fm-branch-eligibility.ts is a thin wrapper that adds the
// node:fs default bindings for callers that just have a state directory; a
// hooks module may import only its own files, so the Claude Code mod imports
// this canonical core directly and binds its host seam itself.


export interface OpenDecisionRecord {
  key: string;
  verb: string;
  note: string;
}

/** The fold's closing-verb and reserved-key configuration, bash defaults. */
export interface FoldVocabulary {
  resolveVerb: string;
  heldVerb: string;
  reservedPrefixes: string[];
  /** Event-vocabulary only; never moves the open set. */
  pausedVerb: string;
}

export const DEFAULT_FOLD_VOCABULARY: FoldVocabulary = {
  resolveVerb: "resolved",
  heldVerb: "captain-held",
  reservedPrefixes: ["pending-reply-"],
  pausedVerb: "paused",
};

/** The FM_CLASSIFY_* names and defaults of bin/fm-classify-lib.sh, exactly. */
export function foldVocabularyFromEnv(getEnv: (name: string) => string | undefined): FoldVocabulary {
  return {
    resolveVerb: getEnv("FM_CLASSIFY_RESOLVE_VERB") || DEFAULT_FOLD_VOCABULARY.resolveVerb,
    heldVerb: getEnv("FM_CLASSIFY_CAPTAIN_HELD_VERB") || DEFAULT_FOLD_VOCABULARY.heldVerb,
    reservedPrefixes: (getEnv("FM_CLASSIFY_RESERVED_KEY_PREFIXES") || "pending-reply-")
      .split(/\s+/)
      .filter(Boolean),
    pausedVerb: getEnv("FM_CLASSIFY_PAUSED_VERB") || DEFAULT_FOLD_VOCABULARY.pausedVerb,
  };
}

/** Leading verb word: up to the first colon, then the first `[`, trimmed,
 * with `corr=<16 hex>` tokens dropped from the remaining whole words. */
export function statusLineVerb(line: string): string {
  const beforeColon = line.split(":", 1)[0].split("[", 1)[0].trim();
  const words = beforeColon.split(/\s+/);
  if (!words.some((word) => word.startsWith("corr="))) return beforeColon;
  return words.filter((word, index) => index === 0 || !/^corr=[0-9a-f]{16}$/i.test(word)).join(" ");
}

/** bin/fm-classify-lib.sh `_fm_status_unstamped` (fold version 9): drop every
 * time-tag-shaped run before the head ends, so a worker-written readable stamp
 * like `[at=10:30]` cannot move the head/note separator the key and note
 * readers below look for. The line's own bytes are never altered. */
export function statusLineUnstamped(line: string): string {
  let rest = line;
  let keep = "";
  for (;;) {
    const start = rest.indexOf("[at=");
    const end = start < 0 ? -1 : rest.indexOf("]", start + 4);
    if (end < 0) break;
    const before = rest.slice(0, start);
    if (before.includes(":")) break;
    keep += before.endsWith(" ") ? before.slice(0, -1) : before;
    rest = rest.slice(end + 1);
  }
  return keep + rest;
}

/** The key a line STATES in one of the parser's declared positions, if any:
 * a complete token before the head's colon, or one at the head of its note.
 * Undefined when the line declares none (unlike decisionKey, which falls back
 * to `default`). */
export function declaredDecisionKey(rawLine: string): string | undefined {
  const line = statusLineUnstamped(rawLine);
  const colon = line.indexOf(":");
  const beforeColon = colon < 0 ? line : line.slice(0, colon);
  const beforeMatch = beforeColon.match(/\[key=([^\]]*)\]/);
  const noteMatch = beforeMatch || colon < 0 ? null : line.slice(colon + 1).trimStart().match(/^\[key=([^\]]*)\]/);
  return (beforeMatch ?? noteMatch)?.[1];
}

/** The `[key=<slug>]` decision key: a complete token before the first colon,
 * else one at the head of the note, else `default`; null when the slug is
 * not well-formed, which makes the line ordinary status here. */
export function decisionKey(line: string): string | null {
  const key = declaredDecisionKey(line) ?? "default";
  return /^[A-Za-z0-9._-]+$/.test(key) ? key : null;
}

/** Text after the first colon, trimmed, with a note-head key token stripped
 * when the key was stated there instead of before the colon. */
export function statusLineNote(rawLine: string): string {
  const line = statusLineUnstamped(rawLine);
  const colon = line.indexOf(":");
  if (colon < 0) return line;
  const note = line.slice(colon + 1).trimStart();
  if (/\[key=[^\]]*\]/.test(line.slice(0, colon))) return note;
  const match = note.match(/^\[key=([A-Za-z0-9._-]+)\]/);
  return match ? note.slice(match[0].length).trimStart() : note;
}

/** A reserved key may only move when the note speaks its namespace's own
 * vocabulary (bin/fm-classify-lib.sh _fm_decision_key_transition_allowed). */
function reservedKeyTransitionAllowed(key: string, note: string, reservedPrefixes: readonly string[]): boolean {
  const prefix = reservedPrefixes.find((candidate) => key.startsWith(candidate));
  if (!prefix) return true;
  return note.startsWith(prefix) && note.slice(prefix.length).includes(":");
}

function withoutRecord(open: readonly OpenDecisionRecord[], key: string): OpenDecisionRecord[] {
  return open.filter((record) => record.key !== key);
}

/** Fold ONE status line into the open set - the v8 rule of
 * bin/fm-classify-lib.sh _fm_decision_fold_line: declaration guard, then the
 * ship/scout terminal close, then open/close by verb, with the key and
 * reserved-prefix rules applied before anything moves. */
export function foldDecisionLine(
  open: readonly OpenDecisionRecord[],
  line: string,
  vocab: FoldVocabulary,
  kind: string,
): OpenDecisionRecord[] {
  // Both colon tests ask where the head ends, the same question the key and
  // note readers ask, so they read the same unstamped copy (bash fold v9).
  const unstamped = statusLineUnstamped(line);
  // Declaration guard: a line holding neither a colon nor a complete
  // "[key=...]" token is continuation prose and can never move the set.
  if (!unstamped.includes(":") && !/\[key=[^\]]*\]/.test(unstamped)) return [...open];
  const verb = statusLineVerb(line);
  // Terminal close: done/failed clears the WHOLE open set for ship and scout.
  if (unstamped.includes(":") && (verb === "done" || verb === "failed") && (kind === "ship" || kind === "scout")) {
    return [];
  }
  if (!["needs-decision", "blocked", vocab.resolveVerb, vocab.heldVerb].includes(verb)) return [...open];
  const key = decisionKey(line);
  if (!key) return [...open];
  const note = statusLineNote(line);
  if (!reservedKeyTransitionAllowed(key, note, vocab.reservedPrefixes)) return [...open];
  if (verb === "needs-decision" || verb === "blocked") {
    return [...withoutRecord(open, key), { key, verb, note }];
  }
  return withoutRecord(open, key);
}

/** Fold a whole status stream (bin/fm-classify-lib.sh status_open_decisions):
 * one record per still-open decision, most-recently-opened-last. */
export function foldStatusLines(
  lines: readonly string[],
  vocab: FoldVocabulary,
  kind: string,
): OpenDecisionRecord[] {
  let open: OpenDecisionRecord[] = [];
  for (const line of lines) open = foldDecisionLine(open, line, vocab, kind);
  return open;
}

/** The bash fold's exact bytes: TAB-separated `<key>\t<verb>\t<note>` lines,
 * newline-separated, no trailing newline, empty string when nothing is open. */
export function serializeOpenDecisions(open: readonly OpenDecisionRecord[]): string {
  return open.map((record) => `${record.key}\t${record.verb}\t${record.note}`).join("\n");
}

/** Task kind per bin/fm-classify-lib.sh _fm_status_kind: the last `kind=`
 * line of a readable meta, `ship` when it is silent, `unknown` when it names
 * anything else or the meta is missing/unreadable/symlinked (pass null). */
export function statusKindFromMetaText(metaText: string | null): string {
  if (metaText === null) return "unknown";
  let kind = "";
  for (const line of metaText.split("\n")) {
    if (line.startsWith("kind=")) kind = line.slice(5);
  }
  if (!kind) kind = "ship";
  return ["ship", "scout", "secondmate"].includes(kind) ? kind : "unknown";
}

/** The v8 stale-row ownership verdict both ports apply: a needs-decision
 * still open in the fold (a merely `blocked` one does not hold a stale row),
 * or the captain-held verb on the last recognized event. */
export function statusDecisionOwned(lines: readonly string[], kind: string, vocab: FoldVocabulary): boolean {
  return hasOpenNeedsDecision(lines, kind, vocab) || currentDeclarationHeld(lines, vocab);
}

/** The second-mate span rule (docs/pi-supervision-branch.md owns the routing
 * contract): a second mate's `.status` stream doubles as its routed-reply
 * channel, so its signal row is judged by the lines NEW since the presented
 * cursor, not by the whole log - a routine close must not stay on main behind
 * an unrelated decision the captain already parked. Walk the span in order: a
 * resolution owns the row only when it closes a decision that was open
 * immediately before that line, and a line that states an open decision's key
 * is that decision's own traffic. */
export function spanDecisionOwned(
  presented: readonly string[],
  span: readonly string[],
  vocab: FoldVocabulary,
  kind: string,
): boolean {
  const openAcrossLog = foldStatusLines([...presented, ...span], vocab, kind);
  let before = foldStatusLines(presented, vocab, kind);
  for (const line of span) {
    const verb = statusLineVerb(line);
    if (["needs-decision", "blocked", vocab.heldVerb].includes(verb)) return true;
    const resolved = verb === vocab.resolveVerb ? decisionKey(line) : null;
    const wasOpen = resolved !== null && before.some((record) => record.key === resolved);
    before = foldDecisionLine(before, line, vocab, kind);
    if (wasOpen && !before.some((record) => record.key === resolved)) return true;
    const declared = declaredDecisionKey(line);
    if (declared !== undefined && openAcrossLog.some((record) => record.key === declared)) return true;
  }
  return false;
}

export function hasOpenNeedsDecision(
  lines: readonly string[],
  kind: string,
  vocab: FoldVocabulary,
): boolean {
  return foldStatusLines(lines, vocab, kind).some((record) => record.verb === "needs-decision");
}

/** The last RECOGNIZED status event (bin/fm-classify-lib.sh
 * _fm_status_event_scan vocabulary), falling back to the last non-blank line
 * only when the log holds no event at all. Continuation prose after a
 * captain-held line must not un-hold the task; a working: line must. */
export function lastStatusLine(lines: readonly string[], vocab: FoldVocabulary): string {
  const eventVerbs = [
    "working",
    "needs-decision",
    "blocked",
    "done",
    "failed",
    "note",
    vocab.pausedVerb,
    vocab.resolveVerb,
    vocab.heldVerb,
  ];
  // bash's FM_CLASSIFY_CAPTAIN_RE_DEFAULT; see the header choice above.
  const legacyCaptainRe = /^\s*(done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged)/i;
  let last = "";
  let fallback = "";
  for (const line of lines) {
    if (!/\S/.test(line)) continue;
    fallback = line;
    const verb = line.includes(":") ? statusLineVerb(line) : "";
    if (eventVerbs.includes(verb) || legacyCaptainRe.test(line)) last = line;
  }
  return last || fallback;
}

export function currentDeclarationHeld(lines: readonly string[], vocab: FoldVocabulary): boolean {
  return statusLineVerb(lastStatusLine(lines, vocab)) === vocab.heldVerb;
}

// ---- the eligible-rows scan -------------------------------------------------

export type UnreadWakeScopeStatus = "safe" | "empty" | "unsafe";

/** The union of the fields the two ports expose with the same meaning, so
 * each adapter maps what its harness consumes. */
export interface UnreadWakeScope {
  status: UnreadWakeScopeStatus;
  eligible: boolean;
  corrupted: boolean;
  eligibleSeqs: string[];
  /** The mod's `<epoch>:<seq>` wake keys, comma-joined (header choice). */
  eligibleWakeKey: string;
  eligibleTasks: string[];
  /** Pi's decision-owned row keys (the queue row's key field). */
  needsDecisionKeys: string[];
  /** The mod's decision-owned task ids. */
  needsDecisionTasks: string[];
  /** The mod's every validated row seq. */
  allSeqs: string[];
  /** Pi's exact project values touched by the eligible rows. */
  projects: string[];
  checkSeqs: string[];
  heartbeatSeqs: string[];
  /** Pi's task id behind each key a claimed row may carry. */
  taskByWakeKey: Record<string, string>;
}

/** One `<task>.meta` record the scan needs. */
export interface QueueMeta {
  task: string;
  project: string;
  window: string;
}

/** A status-log stat bound by the consumer: the stat version string for the
 * verdict cache, or refused - bash's empty-fold outcome for an absent,
 * unreadable, or symlinked log (never a scan refusal). */
export type StatusStat = { state: "ok"; version: string } | { state: "refused" };

/** A status-log read bound by the consumer: the bytes plus the post-read
 * stat version, or refused (bash's empty fold), or torn (the stat version
 * changed or vanished during the read - Pi's rule refuses the scan, header
 * choice). */
export type StatusText =
  | { state: "ok"; text: string; version: string }
  | { state: "refused" }
  | { state: "torn" };

/** Cross-scan verdict cache keyed by task id (Pi's staleDecisionCache; one
 * state directory per runtime, so the task id is the stable key). */
export type DecisionVerdictCache = Map<
  string,
  { version: string; config: string; decisionOwned: boolean }
>;

/** A presented/unread split of one status log, bound by the consumer from the
 * state directory's `.status-presentation-cursor` rows: the already-presented
 * history and the span a new wake covers, or refused/torn exactly as
 * StatusText. A consumer that cannot answer omits the binding, and every
 * second-mate signal row then falls back to the whole-log rule. */
export type StatusSpan =
  | { state: "ok"; presented: string; span: string; version: string }
  | { state: "refused" }
  | { state: "torn" };

export interface UnreadWakeInputs {
  /** The `.wake-queue` bytes, or null when it cannot be read (unsafe scan). */
  queueText: string | null;
  /** Every `.meta` record of the state directory, or null when enumeration
   * failed (unsafe scan). */
  metas: readonly QueueMeta[] | null;
  statStatus(task: string): StatusStat;
  readStatusText(task: string): StatusText;
  /** The presented/unread split a second-mate signal row is judged by; omit
   * to keep every row on the whole-log rule. */
  readPresentedSpan?(task: string): StatusSpan;
  /** The resolved kind (statusKindFromMetaText applied to the meta read). */
  readKind(task: string): string;
  env: FoldVocabulary;
  heartbeat: boolean;
  /** The away collapse (Pi's dispatcher reads the away-posture record): the
   * branch claims check, decision-owned, and heartbeat rows unscoped. */
  afk: boolean;
  /** The attended-host rescan: an attended host can have accepted a routine
   * signal before its task gained a main-owned decision, so a signal row is
   * folded exactly as a stale row is. Absent or false keeps the historical
   * per-row scan, where a needs-decision payload prefix alone holds a signal
   * row. */
  attendedHost?: boolean;
  /** Optional; omit for a pure one-shot scan. */
  cache?: DecisionVerdictCache;
}

const EMPTY_SCOPE: UnreadWakeScope = {
  status: "empty",
  eligible: false,
  corrupted: false,
  eligibleSeqs: [],
  eligibleWakeKey: "",
  eligibleTasks: [],
  needsDecisionKeys: [],
  needsDecisionTasks: [],
  allSeqs: [],
  projects: [],
  checkSeqs: [],
  heartbeatSeqs: [],
  taskByWakeKey: {},
};

const UNSAFE_SCOPE: UnreadWakeScope = {
  status: "unsafe",
  eligible: false,
  corrupted: true,
  eligibleSeqs: [],
  eligibleWakeKey: "",
  eligibleTasks: [],
  needsDecisionKeys: [],
  needsDecisionTasks: [],
  allSeqs: [],
  projects: [],
  checkSeqs: [],
  heartbeatSeqs: [],
  taskByWakeKey: {},
};

/** The eligible-rows and decision-owned classification both ports run, over
 * injected inputs (docs/watcher-continuity.md "Per-actor acknowledgement"
 * owns the consume contract bin/fm-wake-drain.sh implements). A check-kind
 * row never vetoes a scan - it is simply excluded, left queued for main. An
 * unresolvable row, an unknown row kind, or a torn queue row is corruption
 * and vetoes the whole scan. */
export function scopeForUnreadWake(inputs: UnreadWakeInputs): UnreadWakeScope {
  if (inputs.queueText === null) return UNSAFE_SCOPE;
  const rows = inputs.queueText.split(/\r?\n/).filter((line) => line.length > 0);
  // An empty queue is simply nothing to claim, exactly as Pi reads it -
  // before any metadata enumeration can fail.
  if (rows.length === 0) return EMPTY_SCOPE;
  if (inputs.metas === null) return UNSAFE_SCOPE;

  const metadata = new Map<string, string>();
  const taskByKey = new Map<string, string>();
  for (const meta of inputs.metas) {
    if (!meta.project) continue;
    metadata.set(meta.task, meta.project);
    taskByKey.set(meta.task, meta.task);
    taskByKey.set(`${meta.task}.status`, meta.task);
    taskByKey.set(`${meta.task}.turn-ended`, meta.task);
    if (meta.window) {
      metadata.set(meta.window, meta.project);
      taskByKey.set(meta.window, meta.task);
    }
  }

  const { resolveVerb, heldVerb, reservedPrefixes, pausedVerb } = inputs.env;
  const eligibleSeqs: string[] = [];
  const eligibleWakeKey: string[] = [];
  const eligibleTasks = new Set<string>();
  const needsDecisionKeys: string[] = [];
  const needsDecisionTasks: string[] = [];
  const allSeqs: string[] = [];
  const projects = new Set<string>();
  const checkSeqs: string[] = [];
  const heartbeatSeqs: string[] = [];
  const staleOwned = new Map<string, boolean>();
  const verdictConfig = [resolveVerb, heldVerb, pausedVerb, ...reservedPrefixes].join("\0");

  for (const line of rows) {
    const fields = line.split("\t");
    // Torn row: the mod's digit-wise epoch AND seq validation (header choice).
    if (fields.length < 5 || !/^[0-9]+$/.test(fields[0]) || !/^[0-9]+$/.test(fields[1])) return UNSAFE_SCOPE;
    const epoch = fields[0];
    const seq = fields[1];
    allSeqs.push(seq);
    const kind = fields[2];
    const key = fields[3];
    const wakeKey = `${epoch}:${seq}`;
    if (kind === "heartbeat") {
      if (inputs.heartbeat || inputs.afk) {
        eligibleSeqs.push(seq);
        heartbeatSeqs.push(seq);
        eligibleWakeKey.push(wakeKey);
      }
      continue;
    }
    if (kind === "check") {
      if (inputs.afk) {
        eligibleSeqs.push(seq);
        checkSeqs.push(seq);
        eligibleWakeKey.push(wakeKey);
      }
      continue;
    }
    let project = "";
    let task = "";
    if (kind === "signal") {
      task = key.replace(/\.(?:status|turn-ended)$/, "");
      // A second mate's signal is judged by its new span on BOTH paths; every
      // other signal row keeps the historical rule, where only an attended
      // host folds the whole log.
      const spanRule = task !== "" && inputs.readPresentedSpan !== undefined && inputs.readKind(task) === "secondmate";
      if (/^needs-decision:/.test(fields[4] ?? "")) {
        needsDecisionKeys.push(key);
        needsDecisionTasks.push(task);
        if (!inputs.afk) continue;
      } else if (task && (spanRule || inputs.attendedHost)) {
        // An attended host can have accepted a routine signal before its
        // task gained a main-owned decision: fold the status log exactly as
        // a stale row does, so the offer rule keeps that close on main.
        const verdict = staleDecisionVerdict(task, inputs, staleOwned, verdictConfig, spanRule);
        if (verdict === "torn") return UNSAFE_SCOPE;
        if (verdict) {
          needsDecisionKeys.push(key);
          needsDecisionTasks.push(task);
          if (!inputs.afk) continue;
        }
      }
      project = metadata.get(task) ?? "";
    } else if (kind === "stale") {
      task = taskByKey.get(key) ?? taskByKey.get(key.replace(/^fm-/, "")) ?? "";
      project = metadata.get(key) ?? metadata.get(key.replace(/^fm-/, "")) ?? "";
      if (task) {
        const verdict = staleDecisionVerdict(task, inputs, staleOwned, verdictConfig);
        if (verdict === "torn") return UNSAFE_SCOPE;
        if (verdict) {
          needsDecisionKeys.push(key);
          needsDecisionTasks.push(task);
          if (!inputs.afk) continue;
        }
      }
    } else {
      // A row kind this repo's queue writer never emits: corruption.
      return UNSAFE_SCOPE;
    }
    if (!project || !task) return UNSAFE_SCOPE;
    projects.add(project);
    eligibleTasks.add(task);
    eligibleSeqs.push(seq);
    eligibleWakeKey.push(wakeKey);
  }
  const eligible = eligibleSeqs.length > 0;
  return {
    status: eligible ? "safe" : "unsafe",
    eligible,
    corrupted: false,
    eligibleSeqs,
    eligibleWakeKey: eligibleWakeKey.join(","),
    eligibleTasks: [...eligibleTasks],
    needsDecisionKeys,
    needsDecisionTasks,
    allSeqs,
    projects: [...projects],
    checkSeqs,
    heartbeatSeqs,
    taskByWakeKey: Object.fromEntries(taskByKey),
  };
}

/** Per-scan memo over the cross-scan verdict cache: each task's log is
 * folded at most once per scan either way; the cache carries the verdict
 * across scans keyed on the stat version and the fold configuration (header
 * choice), evicting past 512 entries exactly as Pi does. Returns "torn" for
 * Pi's mid-read version change, which refuses the scan. */
function staleDecisionVerdict(
  task: string,
  inputs: UnreadWakeInputs,
  memo: Map<string, boolean>,
  verdictConfig: string,
  spanRule = false,
): boolean | "torn" {
  // One task can carry a stale row and a second-mate signal row in the same
  // queue, and the two rules can disagree, so the rule is part of the key.
  const memoKey = spanRule ? `span\0${task}` : task;
  const memoized = memo.get(memoKey);
  if (memoized !== undefined) return memoized;
  const cache = spanRule ? undefined : inputs.cache;
  const stat = inputs.statStatus(task);
  if (stat.state !== "ok") {
    // refused: bash's empty fold, uncached - an absent log may appear
    // between scans.
    cache?.delete(task);
    memo.set(memoKey, false);
    return false;
  }
  if (spanRule) {
    // ponytail: the span verdict is read once per scan and never cached
    // across scans - the presentation cursor can move without the log
    // changing, so the stat version alone cannot key it. Cache it on the
    // cursor's own offset if a scan ever folds enough second mates to care.
    const read = inputs.readPresentedSpan!(task);
    if (read.state === "torn") return "torn";
    const owned = read.state === "ok"
      && spanDecisionOwned(
        read.presented.split("\n").filter((line) => /\S/.test(line)),
        read.span.split("\n").filter((line) => /\S/.test(line)),
        inputs.env,
        inputs.readKind(task),
      );
    if (read.state === "ok" && read.version !== stat.version) return "torn";
    memo.set(memoKey, owned);
    return owned;
  }
  let owned: boolean;
  const hit = cache?.get(task);
  if (hit && hit.version === stat.version && hit.config === verdictConfig) {
    owned = hit.decisionOwned;
  } else {
    const read = inputs.readStatusText(task);
    if (read.state === "torn") return "torn";
    // refused after a clean stat: bash's empty fold (header choice).
    const lines = read.state === "ok" ? read.text.split("\n").filter((line) => /\S/.test(line)) : [];
    if (read.state === "ok" && read.version !== stat.version) return "torn";
    owned = statusDecisionOwned(lines, inputs.readKind(task), inputs.env);
    cache?.set(task, { version: stat.version, config: verdictConfig, decisionOwned: owned });
    if (cache && cache.size > 512) {
      const oldest = cache.keys().next();
      if (oldest.value !== undefined) cache.delete(oldest.value);
    }
  }
  memo.set(memoKey, owned);
  return owned;
}

