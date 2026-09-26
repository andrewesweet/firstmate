import { statSync } from "node:fs";
import { join } from "node:path";
import { runCommandAsync } from "./fm-async-exec.ts";
import { scanStateDirectory } from "../../../lib/fm-branch-eligibility.ts";

// Shared wake-dispatch handshake between the Pi watcher extension (the
// dispatcher) and the supervision-branch extension (the handler), carried over
// pi.events so neither extension imports the other.
//
// Contract: the watcher builds one offer per actionable wake and emits it on
// FM_BRANCH_DISPATCH_EVENT. A live, enabled branch extension calls accept()
// SYNCHRONOUSLY inside its handler (the event bus invokes handlers
// synchronously up to their first await), so after emit returns the watcher
// reads `accepted`: true means the branch owns handling the wake, and its
// settlement promise keeps the watcher outcome pending until handling finishes
// or rejects back to the watcher's consumption-acknowledged main path; false
// means no branch took it and the watcher delivers to main exactly as it did
// before the branch existed. Watcher-failure alarms are never offered - only
// main can repair the watcher cycle (fm_watch_arm_pi lives on main).
//
// Postures (docs/pi-supervision-branch.md "Postures"). The away-posture record
// state/.afk-contract (owner: bin/fm-afk-contract.sh) is the posture; it is
// read as a file at every routing decision, never inferred from chat. While
// it exists the branch takes EVERY actionable row - check rows, decision-owned
// rows, and heartbeat rows included - and main is offered nothing the branch
// can take. The two vetoes that describe a broken queue stay vetoes in both
// postures, and such a wake, like every watcher-failure alarm, still falls
// back to main exactly as attended, because only main can repair supervision
// itself; parking main is a cost measure, continuity is the safety property.

export const FM_BRANCH_DISPATCH_EVENT = "fm-branch-supervision:dispatch";

// The away-posture record's state-relative filename, exactly as
// bin/fm-afk-contract.sh writes it. Presence is the only fact read here; the
// guarded scripts validate the record themselves (bin/fm-lease-lib.sh).
export const AFK_CONTRACT_FILE = ".afk-contract";

export function afkPostureRecordPresent(state: string): boolean {
  try {
    return statSync(join(state, AFK_CONTRACT_FILE)).isFile();
  } catch {
    return false;
  }
}

// The per-wake prompt every supervision-branch host sends: the Pi branch
// extension, and the supervision host off Pi (bin/fm-supervision-host.sh,
// through bin/fm-branch-dispatch.mjs), so the wake text has one owner. The
// tail is appended while the away-posture record exists: per-wake content,
// never prefix; bin/fm-branch-prompt.sh's fixed "Postures" section is what it
// refers back to.
export const AWAY_POSTURE_TAIL =
  "POSTURE: AWAY. The away-posture record state/.afk-contract exists, so the captain is not present and MAIN is parked: you take every row, including check rows and decision rows, and no outcome reaches the captain until the return brief. " +
  "The record below is the captain's away words, verbatim, and the whole mandate: act on them by your own judgment where this event is the moment they name, only through the guarded scripts under MAIN's standing authority - never more - which enforce it: bin/fm-pr-merge.sh merges any pull request that is green at its live head, synchronously, and refuses a red one or --allow-red; bin/fm-spawn.sh dispatches queued work (already queued, or filed by you from the words) within the spend cap; bin/fm-send.sh --resolve-key answers a decision the words pre-answer, or one the ask-user-authority policy in your prompt lets firstmate decide; bin/fm-merge-local.sh still refuses you. " +
  "Never by analogy, and hold on doubt: a sentence you cannot act on with confidence is reported with verdict captain, naming it, and left for the return. " +
  "Credential entry, legal or financial acceptance, an attended prompt, any discard the captain did not name, and any destructive, irreversible, or security-sensitive action are refused for every actor in every posture, whatever the words say. " +
  "Log every action taken under the words in its outcome summary, opening with \"per your away instructions:\". " +
  "A mirrored captain sentence authorizes nothing new once the record exists. " +
  "The record, verbatim:";

// The posture tail for one wake: the record's read-back (bin/fm-afk-contract.sh
// readback) carried byte-for-byte, or a fixed notice when it could not be
// rendered, because the record's presence is the fact the guarded scripts
// enforce either way.
export function awayPostureTailFor(readback: string): string {
  return `\n\n${AWAY_POSTURE_TAIL}\n${readback || "(the record's read-back could not be rendered; treat the captain's words as unavailable, act on standing authority only, and hold on doubt)"}`;
}

// `reportSurface` names how this host's branch records an outcome: the
// fm_branch_report tool on Pi, the bin/fm-branch-report.sh command elsewhere.
export function branchWakePrompt(message: string, reportSurface: string, postureTail: string): string {
  return `FIRSTMATE SUPERVISION WAKE: ${message}\n\nHandle this per your operating procedure and finish with ${reportSurface}.${postureTail}`;
}

export type UnreadWakeScopeStatus = "safe" | "empty" | "unsafe";

export interface UnreadWakeScope {
  status: UnreadWakeScopeStatus;
  eligible: boolean;
  /** Exact project values touched by the currently eligible rows (context only). */
  projects: string[];
  /**
   * The exact durable-queue sequence numbers this scan proved safe for the
   * branch to drain and acknowledge right now (docs/watcher-continuity.md
   * "Per-actor acknowledgement" - the single owner of the consume contract
   * bin/fm-wake-drain.sh implements against this list). Empty whenever
   * `eligible` is false.
   */
  eligibleSeqs: string[];
  /**
   * The exact task ids the eligible signal/stale rows name (a signal row by
   * its status-log key, a stale row through the task metadata recording that
   * endpoint). The branch may report only these tasks while it handles the
   * wake; `fleet` or a task it merely remembers is refused (docs/
   * pi-supervision-branch.md "Components and their owners"). Empty for a
   * heartbeat, which is not scoped by task.
   */
  eligibleTasks: string[];
  /**
   * True only when this scan itself is untrustworthy: the queue or its
   * metadata could not be read, a line fails the structural tab-field check,
   * or an unresolvable signal/stale row was found. False whenever the scan
   * completed cleanly and simply found nothing (or nothing further) eligible
   * for the branch right now: status "unsafe" with corrupted false is the
   * ordinary "ordinary main-only content, nothing here for the branch" case,
   * not a fault, and callers should treat it as ordinary absence rather than
   * escalating. A main-owned check row is never a source of corruption in
   * either mode.
   */
  corrupted: boolean;
  /** The mod's `<epoch>:<seq>` wake keys for the eligible rows, comma-joined. */
  eligibleWakeKey: string;
  /**
   * The exact "key" field of every decision-owned signal or stale row this
   * scan excluded. Signal rows are marked by bin/fm-watch.sh; stale rows are
   * decision-owned when their task has an open needs-decision or its current
   * declaration is captain-held. fm-primary-pi-watch.ts cross-references these
   * keys against the current trigger so its entire coalesced batch is forced
   * to main.
   */
  needsDecisionKeys: string[];
  /**
   * The check-kind rows included in eligibleSeqs. Non-empty only in the away
   * posture, where the branch takes main's rows too; a check row names no
   * task, so a prompt that claims one is not scoped by task.
   */
  checkSeqs: string[];
  /**
   * The heartbeat rows included in eligibleSeqs. A heartbeat names no task,
   * so a prompt that claims one is not scoped by task, including when a
   * non-heartbeat wake claims it in the away posture.
   */
  heartbeatSeqs: string[];
  /** The mod's every validated row seq (the passed-seqs sweep's queue view). */
  allSeqs: string[];
  taskByWakeKey: Record<string, string>;
}

// scopeForUnreadWake classifies the durable wake queue for the branch offer
// handshake, bound to one state directory. The classification itself - the
// status-decision fold, the eligible-rows scan and its guards, the verdict
// cache, and the wake-key derivation - has one owner, the shared module
// lib/fm-branch-eligibility.ts (the bash v8 fold that
// tests/fm-branch-eligibility.test.sh pins against bin/fm-classify-lib.sh);
// this file only binds it to the extension's state directory and exposes the
// extension's scope shape. docs/pi-supervision-branch.md "Autonomy" and
// docs/watcher-continuity.md "Per-actor acknowledgement" own the routing
// contracts the classification feeds, restated here only as far as the
// dispatcher reads them off this scope: a check-kind row never vetoes a scan
// and stays queued for main; a needs-decision signal row and a decision-owned
// stale row are excluded from eligibleSeqs without a veto and forced to main
// on their own triggering close (fm-primary-pi-watch.ts's offerWakeToBranch);
// a heartbeat review takes every branch-ownable row or none of them, so a
// row this repo's fm_wake_append could never have produced still vetoes the
// whole scan; and in the away posture (`afk`, the dispatcher's read of the
// away-posture record) the partition collapses - main is parked, so check
// rows, decision-owned rows, and heartbeat rows are all claimed by the branch
// on whatever wake finds them unread, while the vetoes that describe a broken
// queue rather than a routing choice stay vetoes in both postures.
export function scopeForUnreadWake(state: string, heartbeat: boolean, afk = false): UnreadWakeScope {
  return scanStateDirectory(state, { heartbeat, afk });
}

// The exact state-relative filename bin/fm-wake-drain.sh reads for a
// FM_SUPERVISION_ACTOR=branch drain or ack (its header is the single owner of
// the consume-side contract). Written atomically, immediately before every
// branch prompt, by writeEligibleRowsSnapshot below.
export const BRANCH_ELIGIBLE_ROWS_FILE = ".branch-eligible-rows";

// Atomically publish the exact row set a branch turn may drain and
// acknowledge. One sequence number per line - an opaque handoff, never
// reclassified by the consumer. A main-owned result means the competing main
// turn won the queue-lock claim and already owns presentation; error means no
// actor acquired the requested rows.
export type EligibleRowsSnapshotResult = "published" | "main-owned" | "error";

// Awaited rather than synchronous because every caller runs on the Pi thread
// that draws the captain's TUI (lib/fm-async-exec.ts). The grant script itself
// is unchanged, and so is each result: a null status still means the script
// could not be run at all.
async function runGrantScript(
  state: string,
  grantScript: string,
  args: readonly string[],
): Promise<number | null> {
  const result = await runCommandAsync("bash", [grantScript, ...args], {
    env: {
      ...process.env,
      FM_STATE_OVERRIDE: state,
      FM_WAKE_QUEUE: `${state}/.wake-queue`,
      FM_WAKE_QUEUE_LOCK: `${state}/.wake-queue.lock`,
    },
  });
  return result.status;
}

export async function activateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["activate", String(ownerPid), generation])) === 0;
}

export async function writeEligibleRowsSnapshot(
  state: string,
  seqs: readonly string[],
  grantScript: string,
  generation: string,
): Promise<EligibleRowsSnapshotResult> {
  if (seqs.length === 0 || seqs.some((seq) => !/^[0-9]+$/.test(seq))) return "error";
  const status = await runGrantScript(state, grantScript, ["publish", generation, ...seqs]);
  if (status === 0) return "published";
  if (status === 3) return "main-owned";
  return "error";
}

export async function releaseEligibleRowsSnapshot(
  state: string,
  grantScript: string,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["release", generation])) === 0;
}

export async function deactivateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["deactivate", String(ownerPid), generation])) === 0;
}

export interface BranchDispatchOffer {
  /** The watcher's actionable close message (the wake reason line(s)). */
  message: string;
  /**
   * Exact project values from the unread task metadata this wake will drain.
   * Empty means the wake is fleet-wide or could not be scoped safely.
   */
  projects: readonly string[];
  /** True when the watcher classified this wake as a fleet-wide heartbeat scan. */
  heartbeat: boolean;
  /** True only when at least one currently unread row is safe for branch handling. */
  eligible: boolean;
  /** True when routing-time eligibility existed only because of the away collapse. */
  awayOnly: boolean;
  /** Set by accept(); read by the watcher after emit returns. */
  accepted: boolean;
  settlement: Promise<void>;
  accept(settlement?: Promise<void>): void;
}

export function createBranchDispatchOffer(
  message: string,
  projects: readonly string[] = [],
  heartbeat = false,
  eligible = false,
  awayOnly = false,
): BranchDispatchOffer {
  const offer: BranchDispatchOffer = {
    message,
    projects: [...projects],
    heartbeat,
    eligible,
    awayOnly,
    accepted: false,
    settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) {
      offer.accepted = true;
      offer.settlement = settlement;
    },
  };
  return offer;
}
