"""Crew-wiki usage reader; contract: assets/crew-wiki-AGENTS.md, Claims and citations."""

import argparse
import datetime
import json
import pathlib
import re


USE = re.compile(r"^used:[ \t]+(\S+)[ \t]+(ok|stale|wrong)[ \t]*$")
DATE = re.compile(r"^date:[ \t]*(\d{4}-\d{2}-\d{2})[ \t]*$", re.M)


def page_key(relative):
    return pathlib.PurePosixPath(relative).relative_to("pages").with_suffix("").as_posix()


def usage_records(repo):
    keys = {page_key(path.relative_to(root.parent))
            for root in (repo / "pages", repo / "archive/pages")
            for path in root.rglob("*.md") if path.is_file()}
    for path in sorted((repo / "raw").rglob("*.md")):
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        header = text.split("\n---\n", 1)
        if not text.startswith("---\n") or len(header) != 2:
            continue
        match = DATE.search(header[0])
        if not match:
            continue
        try:
            day = datetime.date.fromisoformat(match.group(1)).isoformat()
        except ValueError:
            continue
        for line in text.splitlines():
            match = USE.fullmatch(line)
            if match and match.group(1) in keys:
                yield match.group(1), match.group(2), day


def read_usage(repo):
    signals = {}
    for key, verdict, day in usage_records(repo):
        entry = signals.setdefault(key, {"count": 0, "flagged": 0, "last_used": "", "last_ok": ""})
        entry["count"] += 1
        entry["flagged"] += verdict != "ok"
        entry["last_used"] = max(entry["last_used"], day)
        if verdict == "ok":
            entry["last_ok"] = max(entry["last_ok"], day)
    return signals


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", type=pathlib.Path)
    parser.add_argument("--advisories", action="store_true")
    args = parser.parse_args()
    if args.advisories:
        shown = 0
        for key, verdict, day in usage_records(args.repo):
            if verdict == "ok":
                continue
            print(f"wiki lint advisory: usage signal needs the gardener: used: {key} {verdict}")
            shown += 1
            if shown == 20:
                break
    else:
        signals = read_usage(args.repo)
        counts = {key: entry["count"] for key, entry in sorted(signals.items())}
        print(sum(counts.values()), sum(entry["flagged"] for entry in signals.values()),
              json.dumps(counts, separators=(",", ":")), sep="\t")
