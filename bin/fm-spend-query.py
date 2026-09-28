#!/usr/bin/env python3
"""Per-task model-spend figures from a worker's own session logs.

This file owns the spend-ledger line schema (schema 2) and the runtime
coverage list. bin/fm-spend-query.sh is the operator entrypoint that resolves
the task record and calls this file; read that header first for the
command-line contract. bin/fm-spend-ledger-append.sh is the shared producer
that appends one line per closed task; every line it appends is built here, so
the pipeline columns enter a line in exactly one place.

Schema 2, one JSON object per run:
    schema                 always 2 (a schema 1 line is the same object
                           without the pipeline_* keys; normalize_line
                           below reads both)
    task, kind             task id and kind copied from the task record
    harness, model, effort copied from the task record ("unknown"/"default"
                           when the record omits them)
    window                 {"start_epoch": N, "end_epoch": N} records were
                           bounded to, or null when the window could not be
                           established. Both bounds are whole seconds and the
                           end bound covers its whole second, because the
                           producer reads it from a file mtime while records
                           carry sub-second timestamps.
    calls                  deduplicated model calls inside the window
    mean_context_tokens    mean of input + cache_read + cache_write per call
    cache_read_share       cache-read share of the context tokens, 0..1
    usd_lane               "recorded"  the runtime logged its own per-call
                                       cost for every call in the window
                           "api-equiv" priced here at assumed list rates
                           "flat"      reserved for a producer that knows the
                                       task ran under a flat plan; this query
                                       never infers one
                           "unmeasured" no honest figure exists
    usd                    the USD figure; null when unmeasured. An
                           "api-equiv" figure is an estimate at the assumed
                           rates below, never a bill.
    models                 sorted model names seen in the window
    unmeasured_reason      present exactly when usd_lane is "unmeasured"
    pipeline_runs          no-mistakes runs recorded for the task's branch,
                           scoped to the repos the pipeline could have run
                           from: the task's project clone and its own worktree
    pipeline_invocations   agent_invocations rows across those runs
    pipeline_input_tokens, pipeline_output_tokens, pipeline_cache_read_tokens,
    pipeline_cache_creation_tokens
                           token sums over invocations that reported usage
    pipeline_agent_ms      summed agent duration over those invocations
    pipeline_unmeasured_invocations
                           invocations that were killed or never started - a
                           cancelled or error exit_status, or no reported
                           input tokens; counted with their duration, never
                           priced as zero cost
    pipeline_unmeasured_ms summed agent duration over those invocations
    pipeline_usd           priced cost over reported usage whose model
                           matches a known rate prefix; null when no reported
                           usage had a known rate
    pipeline_cost_lane     "api-equiv" every reported token priced here at
                                       assumed list rates
                           "partial"   some reported tokens had no known
                                       rate; pipeline_usd covers the priced
                                       part only
                           "none"      the branch ran no pipeline runs on any
                                       repo in scope, so every pipeline count
                                       is a definitive 0
                           "unmeasured" no honest pipeline figure exists
    pipeline_note          present exactly when pipeline_cost_lane is not
                           "api-equiv"

A teardown ledger line (bin/fm-spend-ledger-append.sh) is this object plus the
producer's own "ts", "outcome", and "outcome_ref" fields.

Runtime coverage - a runtime is measured only when its local session log
exposes per-call usage in a stable, discoverable form verified on an installed
runtime; everything else records an explicit unmeasured reason:
    measured    claude      ~/.claude/projects/<munged-cwd>/*.jsonl; assistant
                            records are deduplicated by message.id because
                            Claude Code writes one record per content block
                            sharing the id; Claude Code logs no price, so USD
                            is api-equiv at the assumed rates below
                pi          <agent-dir>/sessions/--<munged-cwd>--/*.jsonl;
                            per-message usage plus the cost Pi itself recorded;
                            USD is "recorded" only when every in-window call
                            carries that cost, otherwise unmeasured
                pi-signed   the same Pi binary selected by launch markers, so
                            the same session logs and the same parser as pi
    unmeasured  omp, codex, opencode, grok, kimi, cursor, gemini, muse,
                rovo, agy, devin  no verified stable per-call usage parser

The time bound is mandatory: pooled worktrees are reused across tasks and a
slot is handed on the moment a worker exits, so records outside [start, end]
are ignored by every parser. bin/fm-spend-query.sh resolves that window from
the task's own record and activity sidecars; a direct invocation here must pass
the bounds it means with --spawn-epoch and --end-epoch, and a measurement asked
for without them is refused rather than answered over an unbounded window.

The rate table below is the one place USD-per-million-token assumptions live.
These are assumed list rates, not quotes, and they can go stale; an
"api-equiv" label always accompanies them. Update them here and nowhere else.

The pipeline columns are priced at the same table, but unlike the worker
figure they never fall back to a default rate: an invocation whose model
matches no prefix keeps its tokens in the token sums while its cost stays
unmeasured (lane "partial"), because guessing a price is worse than naming
the gap. The no-mistakes state is read through a read-only connection and is
never written; NM_HOME selects the inventory (default ~/.no-mistakes). A repo
there is keyed by the path the pipeline was invoked from, which for a worker
task is its own pooled worktree as often as the project clone, so both scope
the lookup.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 2

# Assumed list rates, USD per million tokens. Keyed by model-name prefix;
# the longest matching prefix wins and the first entry is the documented
# fallback for an unrecognized model.
RATE_TABLE = [
    ("claude-opus", {"input": 5.0, "output": 25.0, "cache_read": 0.5, "cache_write_5m": 6.25, "cache_write_1h": 10.0}),
    ("claude-sonnet", {"input": 3.0, "output": 15.0, "cache_read": 0.3, "cache_write_5m": 3.75, "cache_write_1h": 6.0}),
    ("claude-haiku", {"input": 1.0, "output": 5.0, "cache_read": 0.1, "cache_write_5m": 1.25, "cache_write_1h": 2.0}),
]
DEFAULT_RATES = RATE_TABLE[0][1]

UNMEASURED_DEFAULT_REASON = "no verified per-call usage parser for this runtime"


def rates_for(model: str) -> dict:
    for prefix, rates in RATE_TABLE:
        if model.startswith(prefix):
            return rates
    return DEFAULT_RATES


def rates_for_known(model) -> dict | None:
    """The rate row for a pipeline model, or None when no prefix matches.
    Unlike rates_for this never falls back: an unknown pipeline model keeps
    its tokens while its cost stays unmeasured."""
    if not isinstance(model, str) or not model:
        return None
    best = None
    best_len = -1
    for prefix, rates in RATE_TABLE:
        if model.startswith(prefix) and len(prefix) > best_len:
            best = rates
            best_len = len(prefix)
    return best


def parse_timestamp(value) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def jsonl_records(path: Path):
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    record = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                if isinstance(record, dict):
                    yield record
    except OSError:
        return


def munge_claude_dir(cwd: str) -> str:
    """Claude Code encodes the working directory by replacing every
    non-alphanumeric character with '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def munge_pi_dir(cwd: str) -> str:
    """Pi encodes the working directory as --<cwd with separators as ->--, after
    stripping one leading slash (core/session-manager.js getDefaultSessionDirPath)."""
    stripped = cwd[1:] if cwd.startswith("/") else cwd
    return "--" + stripped.replace("/", "-").replace(":", "-") + "--"


def in_window(record: dict, start: datetime | None, end: datetime | None) -> datetime | None:
    ts = parse_timestamp(record.get("timestamp"))
    if ts is None:
        return None
    if start is not None and ts < start:
        return None
    if end is not None and ts >= end:
        return None
    return ts


def parse_claude(log_dir: Path, start, end):
    """Dedupe assistant usage by message.id inside the window; price at the
    assumed rates for the record's own model."""
    seen: dict[str, tuple[datetime, dict]] = {}
    for path in sorted(log_dir.glob("*.jsonl")):
        for record in jsonl_records(path):
            if record.get("type") != "assistant":
                continue
            message = record.get("message")
            if not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
                continue
            ts = in_window(record, start, end)
            if ts is None:
                continue
            mid = message.get("id") or f"noid-{len(seen)}"
            if mid not in seen:
                seen[mid] = (ts, message)
    calls = []
    models = set()
    usd = 0.0
    cache_read_total = 0
    for _, message in sorted(seen.values(), key=lambda item: item[0]):
        usage = message["usage"]
        cache_creation = usage.get("cache_creation") or {}
        w1h = cache_creation.get("ephemeral_1h_input_tokens", 0)
        w5m = cache_creation.get("ephemeral_5m_input_tokens", max(0, usage.get("cache_creation_input_tokens", 0) - w1h))
        input_tokens = usage.get("input_tokens", 0)
        cache_read = usage.get("cache_read_input_tokens", 0)
        model = message.get("model")
        rates = rates_for(model if isinstance(model, str) else "unknown")
        calls.append(input_tokens + cache_read + w1h + w5m)
        cache_read_total += cache_read
        usd += (
            input_tokens * rates["input"]
            + usage.get("output_tokens", 0) * rates["output"]
            + cache_read * rates["cache_read"]
            + w5m * rates["cache_write_5m"]
            + w1h * rates["cache_write_1h"]
        ) / 1e6
        if isinstance(model, str):
            models.add(model)
    return calls, cache_read_total, round(usd, 4), models


def parse_pi(log_dir: Path, start, end):
    """Sum per-message usage and the cost Pi itself recorded.

    Returns cost_complete alongside the sums: a recorded-lane figure is only
    honest when every in-window call carries the runtime's own cost, so a log
    with any costless call is reported as unmeasured instead of a 0-cost
    "recorded" figure.
    """
    calls = []
    models = set()
    usd = 0.0
    cache_read_total = 0
    cost_complete = True
    for path in sorted(log_dir.glob("*.jsonl")):
        for record in jsonl_records(path):
            message = record.get("message")
            if not isinstance(message, dict) or message.get("role") != "assistant":
                continue
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue
            if in_window(record, start, end) is None:
                continue
            calls.append(usage.get("input", 0) + usage.get("cacheRead", 0) + usage.get("cacheWrite", 0))
            cache_read_total += usage.get("cacheRead", 0)
            cost = (usage.get("cost") or {}).get("total")
            if not isinstance(cost, (int, float)):
                cost_complete = False
            else:
                usd += cost
            if isinstance(message.get("model"), str):
                models.add(message["model"])
    return calls, cache_read_total, round(usd, 4), models, cost_complete


def claude_log_dir(worktree: str) -> Path:
    return Path.home() / ".claude" / "projects" / munge_claude_dir(worktree)


def pi_log_dir(worktree: str) -> Path:
    agent_dir = os.environ.get("PI_CODING_AGENT_DIR") or str(Path.home() / ".pi" / "agent")
    return Path(agent_dir) / "sessions" / munge_pi_dir(worktree)


def parse_claude_complete(log_dir: Path, start, end):
    """Claude Code logs no per-call price, so its cost is always complete at
    the assumed rates: the api-equiv lane never reports a runtime bill."""
    return parse_claude(log_dir, start, end) + (True,)


# One row per covered runtime: parser (returning calls, cache reads, usd,
# models, cost_complete), session-log resolver, and USD lane. A runtime absent
# from this table records an explicit unmeasured reason.
RUNTIMES = {
    "claude": (parse_claude_complete, claude_log_dir, "api-equiv"),
    "pi": (parse_pi, pi_log_dir, "recorded"),
    "pi-signed": (parse_pi, pi_log_dir, "recorded"),
}


def pipeline_defaults() -> dict:
    """The pipeline columns with nothing measured yet; collect_pipeline
    fills them or explains why it could not."""
    return {
        "pipeline_runs": 0,
        "pipeline_invocations": 0,
        "pipeline_input_tokens": 0,
        "pipeline_output_tokens": 0,
        "pipeline_cache_read_tokens": 0,
        "pipeline_cache_creation_tokens": 0,
        "pipeline_agent_ms": 0,
        "pipeline_unmeasured_invocations": 0,
        "pipeline_unmeasured_ms": 0,
        "pipeline_usd": None,
        "pipeline_cost_lane": "unmeasured",
        "pipeline_note": "pipeline not queried",
    }


def nm_state_root() -> Path:
    root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
    return root


def collect_pipeline(branch: str | None, project: str | None, worktree: str | None = None) -> dict:
    """Aggregate the no-mistakes agent_invocations for one task branch.
    The inventory keys a repo by the path the pipeline ran from, which for a
    worker task is its own pooled worktree as often as the project clone, so
    both scope the lookup: a repo whose working_path is the project, is the
    worktree, or sits inside the worktree. The inventory is opened read-only
    and never written. Invocations that reported no tokens (killed or never
    started) are counted with their duration and never priced."""
    pipeline = pipeline_defaults()
    if not branch:
        pipeline["pipeline_note"] = "task record carries no branch; no pipeline runs to attribute"
        pipeline["pipeline_cost_lane"] = "none"
        return pipeline
    scopes = [path for path in (project, worktree) if path]
    if not scopes:
        pipeline["pipeline_note"] = (
            "task record carries neither project nor worktree; pipeline repo cannot be resolved"
        )
        return pipeline
    db_path = nm_state_root() / "state.sqlite"
    if not db_path.is_file():
        pipeline["pipeline_note"] = f"no-mistakes state not found at {db_path}"
        return pipeline
    prefix = worktree.rstrip("/") + "/" if worktree else None
    try:
        import sqlite3
        db = sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True, timeout=5)
        try:
            db.execute("SELECT 1 FROM runs LIMIT 1")
            repo_ids = [
                repo_id
                for repo_id, path in db.execute("SELECT id, working_path FROM repos")
                if isinstance(path, str)
                and (path in scopes or (prefix is not None and path.startswith(prefix)))
            ]
            if repo_ids:
                placeholders = ",".join("?" for _ in repo_ids)
                run_rows = db.execute(
                    f"SELECT id FROM runs WHERE repo_id IN ({placeholders}) AND branch = ? "
                    "ORDER BY created_at",
                    (*repo_ids, branch),
                ).fetchall()
            else:
                run_rows = []
            run_ids = [row[0] for row in run_rows]
            if run_ids:
                placeholders = ",".join("?" for _ in run_ids)
                columns = (
                    "model, input_tokens, output_tokens, cache_read_tokens, "
                    "cache_creation_tokens, duration_ms"
                )
                try:
                    invocations = db.execute(
                        f"SELECT {columns}, exit_status FROM agent_invocations "
                        f"WHERE run_id IN ({placeholders})",
                        run_ids,
                    ).fetchall()
                except sqlite3.OperationalError:
                    invocations = [
                        (*row, None)
                        for row in db.execute(
                            f"SELECT {columns} FROM agent_invocations "
                            f"WHERE run_id IN ({placeholders})",
                            run_ids,
                        ).fetchall()
                    ]
            else:
                invocations = []
        finally:
            db.close()
    except Exception as exc:
        pipeline["pipeline_note"] = f"no-mistakes state unreadable: {exc}"
        return pipeline
    if not repo_ids:
        pipeline["pipeline_note"] = (
            "no-mistakes repo not resolved for " + " or ".join(scopes)
        )
        return pipeline
    if not run_ids:
        pipeline["pipeline_cost_lane"] = "none"
        pipeline["pipeline_note"] = f"no no-mistakes runs recorded for branch {branch}"
        return pipeline
    priced_usd = 0.0
    priced_tokens = 0
    unpriced_models: set[str] = set()
    for model, input_tokens, output_tokens, cache_read, cache_creation, duration_ms, exit_status in invocations:
        duration = duration_ms if isinstance(duration_ms, int) else 0
        if input_tokens is None or exit_status in ("cancelled", "error"):
            pipeline["pipeline_unmeasured_invocations"] += 1
            pipeline["pipeline_unmeasured_ms"] += duration
            continue
        output = output_tokens if isinstance(output_tokens, int) else 0
        read = cache_read if isinstance(cache_read, int) else 0
        created = cache_creation if isinstance(cache_creation, int) else 0
        pipeline["pipeline_input_tokens"] += input_tokens
        pipeline["pipeline_output_tokens"] += output
        pipeline["pipeline_cache_read_tokens"] += read
        pipeline["pipeline_cache_creation_tokens"] += created
        pipeline["pipeline_agent_ms"] += duration
        rates = rates_for_known(model)
        if rates is None:
            unpriced_models.add(model or "unknown")
            continue
        priced_tokens += input_tokens + output + read + created
        priced_usd += (
            input_tokens * rates["input"]
            + output * rates["output"]
            + read * rates["cache_read"]
            + created * rates["cache_write_5m"]
        ) / 1e6
    pipeline["pipeline_runs"] = len(run_ids)
    pipeline["pipeline_invocations"] = len(invocations)
    measured = pipeline["pipeline_invocations"] - pipeline["pipeline_unmeasured_invocations"]
    if measured == 0:
        pipeline["pipeline_note"] = (
            "every invocation was killed or reported no tokens; "
            "every pipeline cost stays unmeasured"
        )
        return pipeline
    if unpriced_models:
        named = ", ".join(sorted(unpriced_models))
        if not priced_tokens:
            pipeline["pipeline_note"] = (
                "no known rate for model(s) " + named + "; no invocation could be priced"
            )
            return pipeline
        pipeline["pipeline_cost_lane"] = "partial"
        pipeline["pipeline_usd"] = round(priced_usd, 4)
        pipeline["pipeline_note"] = (
            "no known rate for model(s) " + named + "; "
            "pipeline_usd covers the priced invocations only"
        )
        return pipeline
    pipeline["pipeline_cost_lane"] = "api-equiv"
    pipeline["pipeline_usd"] = round(priced_usd, 4)
    pipeline.pop("pipeline_note", None)
    return pipeline


def normalize_line(line: dict) -> dict:
    """Read a ledger line of any known schema and return its schema 2 form.
    A schema 1 line gains the default pipeline columns; unknown fields pass
    through untouched and unknown schemas are refused."""
    if not isinstance(line, dict):
        raise ValueError("ledger line must be a JSON object")
    schema = line.get("schema")
    if schema == SCHEMA_VERSION:
        normalized = dict(line)
        for key, value in pipeline_defaults().items():
            normalized.setdefault(key, value)
        if normalized.get("pipeline_cost_lane") == "api-equiv":
            normalized.pop("pipeline_note", None)
        return normalized
    if schema == 1:
        normalized = dict(line)
        normalized["schema"] = SCHEMA_VERSION
        normalized.update(pipeline_defaults())
        normalized["pipeline_note"] = "recorded before pipeline columns existed"
        return normalized
    raise ValueError(f"unsupported ledger schema: {schema!r}")


def unmeasured(base: dict, reason: str) -> dict:
    line = dict(base)
    line.update({
        "window": base.get("window"),
        "calls": None,
        "mean_context_tokens": None,
        "cache_read_share": None,
        "usd_lane": "unmeasured",
        "usd": None,
        "models": [],
        "unmeasured_reason": reason,
    })
    return line


def build_line(args) -> dict:
    harness = args.harness or "unknown"
    base = {
        "schema": SCHEMA_VERSION,
        "task": args.task,
        "kind": args.kind,
        "harness": harness,
        "model": args.model or "default",
        "effort": args.effort or "default",
    }
    # The pipeline figure is independent of the worker figure: a task whose
    # worker session cannot be measured may still have pipeline runs, and a
    # task with no branch has definitively no pipeline runs to attribute.
    pipeline = collect_pipeline(
        getattr(args, "pipeline_branch", None),
        getattr(args, "pipeline_project", None),
        args.worktree or None,
    )
    if args.unmeasured:
        return {**unmeasured(base, args.unmeasured), **pipeline}
    if harness not in RUNTIMES:
        return {**unmeasured(base, UNMEASURED_DEFAULT_REASON), **pipeline}
    if not args.worktree:
        return {**unmeasured(base, "task record carries no worktree path"), **pipeline}

    if args.spawn_epoch is None or args.end_epoch is None:
        raise SystemExit(
            "error: a measured figure needs both --spawn-epoch and --end-epoch; "
            "worktrees are pooled, so an unbounded window would sum other tasks' calls"
        )

    start = datetime.fromtimestamp(args.spawn_epoch, tz=timezone.utc)
    end = datetime.fromtimestamp(args.end_epoch + 1, tz=timezone.utc)
    window = {"start_epoch": args.spawn_epoch, "end_epoch": args.end_epoch}

    parse, resolve_log_dir, usd_lane = RUNTIMES[harness]
    log_dir = resolve_log_dir(args.worktree)
    if not log_dir.is_dir():
        return {**unmeasured({**base, "window": window}, f"no session log directory found for the task worktree: {log_dir}"), **pipeline}

    calls, cache_read, usd, models, cost_complete = parse(log_dir, start, end)
    if not calls:
        return {**unmeasured({**base, "window": window}, "no model-call usage records found inside the task window"), **pipeline}
    if not cost_complete:
        return {**unmeasured({**base, "window": window}, "runtime log lacks per-call cost for some or all calls"), **pipeline}

    context_total = sum(calls)
    line = dict(base)
    line.update({
        "window": window,
        "calls": len(calls),
        "mean_context_tokens": round(context_total / len(calls)),
        "cache_read_share": round(cache_read / context_total, 3) if context_total else 0.0,
        "models": sorted(models),
        "usd_lane": usd_lane,
        "usd": usd,
    })
    line.update(pipeline)
    return line


def main() -> int:
    parser = argparse.ArgumentParser(description="Per-task model-spend figures from worker session logs (schema owner: this file's docstring).")
    parser.add_argument("--task", required=True)
    parser.add_argument("--kind", default="")
    parser.add_argument("--harness", default="")
    parser.add_argument("--model", default="")
    parser.add_argument("--effort", default="")
    parser.add_argument("--worktree", default="")
    parser.add_argument("--spawn-epoch", type=int, default=None)
    parser.add_argument("--end-epoch", type=int, default=None)
    parser.add_argument("--pipeline-branch", default=None,
                        help="task ship branch; its no-mistakes runs supply the pipeline columns")
    parser.add_argument("--pipeline-project", default=None,
                        help="absolute project clone path scoping the pipeline branch lookup; "
                             "--worktree scopes it too, because a pipeline run is keyed by the "
                             "path it ran from")
    parser.add_argument("--unmeasured", default="",
                        help="skip measurement and emit the unmeasured shape with this reason, "
                             "still carrying the pipeline columns for --pipeline-branch")
    parser.add_argument("--normalize-line", action="store_true",
                        help="read one ledger line on stdin and print its schema 2 form")
    args = parser.parse_args()
    if args.normalize_line:
        print(json.dumps(normalize_line(json.load(sys.stdin))))
        return 0
    print(json.dumps(build_line(args)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
