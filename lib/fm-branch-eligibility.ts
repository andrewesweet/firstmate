// Thin wrapper over the canonical shared fold core: re-exports the pure
// core and adds the node:fs default bindings that plain callers need. The
// canonical core lives under the Claude Code mod
// (.claude/mods/fm-branch-mod/lib/fm-branch-eligibility.ts) because a hooks
// module may import only its own files, so this repo side points at it
// instead (the Calm-mod pattern, inverted; the mod binds its own host seam
// itself). The import goes through the sibling symlink
// lib/fm-branch-eligibility-core.ts so a plain file copy of lib/ keeps the
// pair resolvable.
// tests/fm-branch-eligibility.test.sh pins the fold through this wrapper
// against the bash fold on one fixture set, so wherever this module and bash
// disagree, the test fails.

import { foldStatusLines, foldVocabularyFromEnv, scopeForUnreadWake, serializeOpenDecisions, statusKindFromMetaText } from "./fm-branch-eligibility-core.ts";
import type { DecisionVerdictCache, QueueMeta, StatusStat, StatusText, UnreadWakeScope } from "./fm-branch-eligibility-core.ts";
export * from "./fm-branch-eligibility-core.ts";
import { execFileSync } from "node:child_process";
import { lstatSync, readdirSync, readFileSync } from "node:fs";
import type { StatusSpan } from "./fm-branch-eligibility-core.ts";

// ---- thin default bindings over node:fs ------------------------------------
// What the equivalence test and a plain caller need: bind the pure core to
// one state directory with lstat-based symlink refusal (bash truth), the
// FM_CLASSIFY_* environment, and one module-level verdict cache (Pi's
// posture: one state directory per runtime, so task ids are stable keys).

const defaultVerdictCache: DecisionVerdictCache = new Map();

/** The lstat version of a plain file, or null for a missing, unreadable, or
 * symlinked path - bash's `[ -f ] && [ -r ] && [ ! -L ]` guard. */
function statVersion(path: string): string | null {
  try {
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) return null;
    return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
  } catch {
    return null;
  }
}

function statStatusOnDisk(state: string, task: string): StatusStat {
  const version = statVersion(`${state}/${task}.status`);
  return version === null ? { state: "refused" } : { state: "ok", version };
}

function readStatusTextOnDisk(state: string, task: string): StatusText {
  const path = `${state}/${task}.status`;
  if (statVersion(path) === null) return { state: "refused" };
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return { state: "refused" };
  }
  const version = statVersion(path);
  return version === null ? { state: "torn" } : { state: "ok", text, version };
}

// bin/fm-classify-lib.sh's _fm_open_decisions_file_ident, which stamps each
// row of state/.status-presentation-cursor. Any failure throws, and the caller
// then reads the whole log as the span.
function statusFileIdentity(path: string): string {
  const darwin = process.platform === "darwin";
  const output = execFileSync(
    darwin ? "/usr/bin/stat" : "stat",
    darwin ? ["-f", "%d:%i|%B|%FB", path] : ["-c", "%d:%i|%W|%w", path],
    { encoding: "utf8", env: { ...process.env, LC_ALL: "C" }, stdio: ["ignore", "pipe", "ignore"] },
  ).trim();
  const [ident, birthEpoch, birth] = output.split("|");
  if (!ident || !birthEpoch) throw new Error("status identity unavailable");
  return birthEpoch !== "0" && birth ? `strong:${ident}:${birth}` : `weak:${ident}`;
}

/** The per-task presentation-cursor rows (task, identity, presented offset,
 * backstop), in the format bin/fm-classify-lib.sh writes
 * (status_presentation_cursor_offset reads the same rows). Null when the
 * cursor is absent or malformed, so every span read falls back to the whole
 * log. */
function readPresentationCursor(state: string): Map<string, { ident: string; offset: number } | null> | null {
  try {
    const path = `${state}/.status-presentation-cursor`;
    if (!lstatSync(path).isFile()) return null;
    const rows = new Map<string, { ident: string; offset: number } | null>();
    for (const row of readFileSync(path, "utf8").split("\n")) {
      if (!row) continue;
      const [task, ident, offset, backstop = "", ...extra] = row.split("\t");
      if (!task || !ident || !/^[0-9]+$/.test(offset ?? "") || !/^[0-9]*$/.test(backstop) || extra.length > 0) return null;
      rows.set(task, rows.has(task) ? null : { ident, offset: Number(offset) });
    }
    return rows;
  } catch {
    return null;
  }
}

/** One task's presented/unread split at the presentation cursor: the span is
 * the whole log whenever no trustworthy cursor row covers it (absent,
 * malformed, a rotated identity, or an offset past the log). */
function readPresentedSpanOnDisk(state: string, task: string): StatusSpan {
  const path = `${state}/${task}.status`;
  if (statVersion(path) === null) return { state: "refused" };
  let bytes: Buffer;
  try {
    bytes = readFileSync(path);
  } catch {
    return { state: "refused" };
  }
  const version = statVersion(path);
  if (version === null) return { state: "torn" };
  const cursor = readPresentationCursor(state)?.get(task);
  let offset = 0;
  if (cursor && cursor.offset <= bytes.length) {
    try {
      if (cursor.ident === statusFileIdentity(path)) offset = cursor.offset;
    } catch {
      // No identity to match: the span is the whole log.
    }
  }
  return {
    state: "ok",
    presented: bytes.subarray(0, offset).toString("utf8"),
    span: bytes.subarray(offset).toString("utf8"),
    version,
  };
}

function readMetaKindOnDisk(state: string, task: string): string {
  const path = `${state}/${task}.meta`;
  try {
    if (lstatSync(path).isSymbolicLink()) return "unknown";
  } catch {
    return "unknown";
  }
  try {
    return statusKindFromMetaText(readFileSync(path, "utf8"));
  } catch {
    return "unknown";
  }
}

function listQueueMetas(state: string): QueueMeta[] | null {
  try {
    const metas: QueueMeta[] = [];
    for (const entry of readdirSync(state, { withFileTypes: true })) {
      if (!entry.name.endsWith(".meta")) continue;
      const task = entry.name.slice(0, -5);
      const fields = readFileSync(`${state}/${entry.name}`, "utf8").split("\n");
      metas.push({
        task,
        project: fields.find((line) => line.startsWith("project="))?.slice(8) ?? "",
        window: fields.find((line) => line.startsWith("window="))?.slice(7) ?? "",
      });
    }
    return metas;
  } catch {
    return null;
  }
}

export interface StateDirectoryScanOptions {
  heartbeat?: boolean;
  afk?: boolean;
  /** The attended-host rescan, passed into the shared fold (default false). */
  attendedHost?: boolean;
  cache?: DecisionVerdictCache;
}

/** The scan bound to one state directory over node:fs, with the
 * FM_CLASSIFY_* environment and the module-level verdict cache. */
export function scanStateDirectory(state: string, options: StateDirectoryScanOptions = {}): UnreadWakeScope {
  let queueText: string | null;
  try {
    queueText = readFileSync(`${state}/.wake-queue`, "utf8");
  } catch {
    queueText = null;
  }
  return scopeForUnreadWake({
    queueText,
    metas: listQueueMetas(state),
    statStatus: (task) => statStatusOnDisk(state, task),
    readStatusText: (task) => readStatusTextOnDisk(state, task),
    readPresentedSpan: (task) => readPresentedSpanOnDisk(state, task),
    readKind: (task) => readMetaKindOnDisk(state, task),
    env: foldVocabularyFromEnv((name) => process.env[name]),
    heartbeat: options.heartbeat ?? false,
    afk: options.afk ?? false,
    attendedHost: options.attendedHost ?? false,
    cache: options.cache ?? defaultVerdictCache,
  });
}

/** The bash fold bound to one status log on disk: bash's empty-fold outcome
 * for an absent, unreadable, or symlinked log, the sibling `.meta` kind, and
 * the FM_CLASSIFY_* environment. Emits serializeOpenDecisions bytes - the
 * exact bytes `status_open_decisions` prints. One read pass, bash's own
 * shape - no torn check, since bash folds whatever bytes its single read
 * captured. */
export function foldStatusLog(dir: string, task: string): string {
  const read = readStatusTextOnDisk(dir, task);
  if (read.state !== "ok") return "";
  const lines = read.text.split("\n");
  const vocab = foldVocabularyFromEnv((name) => process.env[name]);
  return serializeOpenDecisions(foldStatusLines(lines, vocab, readMetaKindOnDisk(dir, task)));
}
