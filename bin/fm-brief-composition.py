#!/usr/bin/env python3
"""Split a task brief's token weight into scaffold and task-specific parts.

bin/fm-spawn.sh calls this with the filled task brief and a freshly generated
same-shape scaffold (bin/fm-brief.sh into a temporary home); the difference is
what the intake actually asked for. Repeatable --map FROM=TO arguments are
applied to the scaffold text before the comparison so the scaffold's baked
absolute paths (status-append, inbox, report lines) compare equal to the
filled brief's real-home paths. Prints one JSON object:

    {"scaffold_tokens": <fixed brief chars/4>,
     "task_tokens":     <task-specific chars/4, floored at 0>,
     "fixed_share":     <scaffold share of the filled brief, 3 decimals>}

Tokens are characters over 4, the same estimate everywhere else in firstmate.
Fixed lines are the filled brief's lines that also appear verbatim in the
scaffold; the measure is best-effort and prints nothing on a bad input.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def read_lines(path: str, replacements: list[tuple[str, str]]) -> list[str]:
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    for src, dst in replacements:
        text = text.replace(src, dst)
    return text.splitlines()


def parse_maps(args: list[str]) -> list[tuple[str, str]]:
    maps: list[tuple[str, str]] = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--map":
            i += 1
            if i >= len(args):
                return []
            arg = args[i]
        elif arg.startswith("--map="):
            arg = arg[len("--map="):]
        else:
            i += 1
            continue
        src, sep, dst = arg.partition("=")
        if not sep or not src:
            return []
        maps.append((src, dst))
        i += 1
    # Longest source first so a state-path prefix wins over its home prefix.
    return sorted(maps, key=lambda m: len(m[0]), reverse=True)


def main() -> int:
    args = sys.argv[1:]
    maps = parse_maps(args)
    if not maps and any(a == "--map" or a.startswith("--map=") for a in args):
        return 2
    paths = []
    i = 0
    while i < len(args):
        if args[i] == "--map":
            i += 2
        elif args[i].startswith("--map="):
            i += 1
        else:
            paths.append(args[i])
            i += 1
    if len(paths) != 2:
        return 2
    brief_lines = read_lines(paths[0], [])
    scaffold_lines = read_lines(paths[1], maps)
    if not brief_lines or not scaffold_lines:
        return 2

    scaffold_set = set(scaffold_lines)
    fixed_chars = sum(len(line) + 1 for line in brief_lines if line in scaffold_set)
    total_chars = sum(len(line) + 1 for line in brief_lines)
    scaffold_tokens = fixed_chars // 4
    task_tokens = max(0, (total_chars - fixed_chars) // 4)
    fixed_share = round(fixed_chars / total_chars, 3) if total_chars else 0.0
    print(json.dumps({
        "scaffold_tokens": scaffold_tokens,
        "task_tokens": task_tokens,
        "fixed_share": fixed_share,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
