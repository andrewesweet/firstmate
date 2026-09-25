#!/usr/bin/env python3
"""Per-task model-spend figures from a worker's own session logs.

This file owns the spend-ledger line schema (schema 1) and the runtime
coverage list. bin/fm-spend-query.sh is the operator entrypoint that resolves
the task record and calls this file; read that header first for the
command-line contract.

Schema 1, one JSON object per run:
    schema                 always 1
    task, kind             task id and kind copied from the task record
    harness, model, effort copied from the task record ("unknown"/"default"
                           when the record omits them)
    window                 {"start_epoch": N, "end_epoch": N} records were
                           bounded to, or null when the window could not be
                           established
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

A teardown ledger line (bin/fm-teardown.sh) is this object plus the teardown's
own "ts", "outcome", and "outcome_ref" fields.

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
the bounds it means with --spawn-epoch and --end-epoch.

The rate table below is the one place USD-per-million-token assumptions live.
These are assumed list rates, not quotes, and they can go stale; an
"api-equiv" label always accompanies them. Update them here and nowhere else.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1

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
    if end is not None and ts > end:
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
    if harness not in RUNTIMES:
        return unmeasured(base, UNMEASURED_DEFAULT_REASON)
    if not args.worktree:
        return unmeasured(base, "task record carries no worktree path")

    start = datetime.fromtimestamp(args.spawn_epoch, tz=timezone.utc) if args.spawn_epoch is not None else None
    end = datetime.fromtimestamp(args.end_epoch, tz=timezone.utc) if args.end_epoch is not None else None
    window = {"start_epoch": args.spawn_epoch, "end_epoch": args.end_epoch}

    parse, resolve_log_dir, usd_lane = RUNTIMES[harness]
    log_dir = resolve_log_dir(args.worktree)
    if not log_dir.is_dir():
        return unmeasured({**base, "window": window}, f"no session log directory found for the task worktree: {log_dir}")

    calls, cache_read, usd, models, cost_complete = parse(log_dir, start, end)
    if not calls:
        return unmeasured({**base, "window": window}, "no model-call usage records found inside the task window")
    if not cost_complete:
        return unmeasured({**base, "window": window}, "runtime log lacks per-call cost for some or all calls")

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
    args = parser.parse_args()
    print(json.dumps(build_line(args)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
