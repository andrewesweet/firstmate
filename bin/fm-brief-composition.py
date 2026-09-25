#!/usr/bin/env python3
"""Split a task brief's token weight into scaffold and task-specific parts.

bin/fm-spawn.sh calls this with the filled task brief and a freshly generated
same-shape scaffold (bin/fm-brief.sh into a temporary home); the difference is
what the intake actually asked for. Prints one JSON object:

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


def read_lines(path: str) -> list[str]:
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return text.splitlines()


def main() -> int:
    if len(sys.argv) != 3:
        return 2
    brief_lines = read_lines(sys.argv[1])
    scaffold_lines = read_lines(sys.argv[2])
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
