# Test scope and outcome

The changed product surface is Markdown emitted by `bin/fm-brief.sh` and the shared `fm_dod_block` interface. The live checks invoked those real interfaces with isolated homes and retained their delivered output. Assertions use the supplied intent and accepted fix decisions as the oracle. They do not claim that an LLM followed the instructions or that any pipeline response, push, or CI operation was executed.

`drive-generated-briefs.py` passed all generated-interface scenarios: GitHub bounded polling and feedback reads; parked-gate fix routing; keyed escalation and post-green follow-up; maintainer waits and custom pause verbs; standalone defaults; Forgejo pagination and per-review inline reads; and exclusion from other delivery modes.

Selected existing generated-output checks passed, as did `test_arm_plumbs_a_configured_budget_into_the_check_shim`. No linters, formatters, static-analysis checks, or complete repository suite ran.

The remote lifecycle regression initially stopped at the fleet lifecycle guard because fixture processes inherited the gate checkout through a worktree-local TMPDIR. Re-running the unchanged test with disposable temporary fixtures under the evidence directory passed, including both held-clone races and remote liveness/relaunch checks. That suite uses simulated SSH/Herdr boundaries; its results are regression evidence, not live remote or harness evidence. Both runs' logs are retained. Their temporary fixtures were removed by the test cleanup.

No source files changed. No actual no-mistakes pipeline operations or live fleet operations ran. The surface is CLI-generated Markdown; there is no changed rendered UI requiring a screenshot.
