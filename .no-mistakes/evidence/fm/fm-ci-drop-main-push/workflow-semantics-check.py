import json
import subprocess
from pathlib import Path

import yaml

BASE = "cccc756f28cf67396963143a5aadc07e4559a4de"
TARGET = "75450f8675d06f98ec589a5f564ead57a7d2323c"
WORKFLOW = ".github/workflows/ci.yml"


def workflow_at(revision):
    raw = subprocess.check_output(["git", "show", f"{revision}:{WORKFLOW}"], text=True)
    document = yaml.safe_load(raw)
    # PyYAML's YAML 1.1 loader resolves the plain key `on` as boolean true.
    events = document.pop("on", None)
    if events is None:
        events = document.pop(True)
    assert isinstance(events, dict), "workflow events must be a mapping"
    return document, events


base, before = workflow_at(BASE)
target, after = workflow_at(TARGET)
assert set(after) == {"pull_request"}, after
assert after["pull_request"] == before["pull_request"] == {"branches": ["main"]}
assert "push" in before and "push" not in after
assert base == target, "workflow settings or jobs changed beyond event removal"
assert set(target["jobs"]) == {
    "lint", "test-coverage", "tests-portable-parallel-1", "tests-portable-parallel-2",
    "tests-portable-serial", "tests-herdr", "macos-stock-bash", "invariants",
    "tests-timing-aggregate",
}
report = {
    "contract": "GitHub Actions CI workflow YAML semantic configuration",
    "scope": "Offline normalized configuration check; no GitHub event was delivered or run observed",
    "base_commit": BASE,
    "target_commit": TARGET,
    "events_before": before,
    "events_after": after,
    "counterfactual": {
        "base_satisfies_pull_request_only": set(before) == {"pull_request"},
        "target_satisfies_pull_request_only": set(after) == {"pull_request"},
    },
    "pull_request_branch_filter_preserved": after["pull_request"] == before["pull_request"],
    "all_other_workflow_settings_and_jobs_unchanged": base == target,
    "concurrency": target["concurrency"],
    "retained_jobs": {
        name: {"timeout_minutes": job["timeout-minutes"], "matrix": job.get("strategy", {}).get("matrix")}
        for name, job in target["jobs"].items()
    },
}
output = Path(__file__).with_name("workflow-semantics.json")
output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
