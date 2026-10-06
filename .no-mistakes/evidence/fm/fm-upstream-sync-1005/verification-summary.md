# Local product verification

Target: `5223f111c899b79eb34ad6dea06f821ba17db0ae`; base: `65a0e6747526320dd2719a3993d8281a6c4b5580`.

The submitted history contains a true two-parent upstream merge and descends from `e5b9dddc`. The upstream range after the common ancestor contains 23 commits. These are history checks, not live runtime scenarios; see `merge-history.log`.

Fourteen selected suites ultimately passed without gate skips. The first two invocations placed temporary fixture homes underneath this gate worktree. That broke fixtures which reject homes inside the Firstmate repository or embed TMPDIR into Git branch names. Retrying the affected subjects with the toolchain's ordinary `/tmp` fixture location resolved those failures. Initial and corrected outputs are retained, rather than describing the initial invocations as green:

- `targeted-tests.log`: eight selected subjects, four setup failures.
- `preserved-contract-tests.log`: seven selected subjects, brief setup failure; the other six passed.
- `brief-normal-tmp.log`: corrected brief subject passed.
- `targeted-normal-tmp.log`: seven corrected subjects passed.

The regression seam for R2 failed on parent `15e2d704` and passed at the submitted head. The previous implementation emitted a null branch and null reflog boundary after return. The corrected implementation retained `fm/task-x1`, its creation boundary, and the eligible measured run while excluding older and other-branch runs. This seam uses inventory/Treehouse fixtures, so it is not labeled live. See `r2-before-regression.log` and `r2-after-regression.log`.

Separately, `r2-proof.py` drove real Treehouse and real Firstmate teardown. An ownership-verified legacy return detached HEAD yet retained the original task branch and reflog boundary in the ledger. A foreign lease refused return and preserved the branch, metadata, and existing ledger. The disposable no-mistakes inventory was uninitialized: this live proof records unavailable totals truthfully and does not claim measured pipeline totals. See `legacy-real-treehouse.log` and `legacy-pipeline-spend.jsonl`.

`named-spawn.py` provisioned a named non-default Herdr lab through the repository helper, scaffolded the lab contract, and spawned a real Pi scout using the normal existing login. Both the task record and the real leased checkout pointed at `release/next`; the actual starting commit matched its distinct sentinel commit. The real scout read it and wrote `named-base-scout-report.md`. Herdr teardown passed and the lease was returned. The protected hooks directory needed owner write permission to remove the disposable lab; cleanup was completed. No production fleet or pool was administered.

`live-checks.py` drove real public interfaces in disposable homes for brief generation and mismatch refusal, multiline hold preservation and exact answer retry, opt-in unavailable spend and independent ledgers, per-host cap admission/refusal, remote delta continuity and traversal refusal, a real remote worker, concurrent watcher arms, and supervision-host/branch-mode mutual exclusion. See `live-cli.log` and the generated state artifacts.

`typed-live.py` and `typed-clear.py` used the real Jev service and real quota-axi consumer with a supported disposable quota snapshot. Clear resolution produced typed profile arguments, an approval-required rule escalated without a launchable profile, and a never-send instruction disabled dispatch. No production quota records were read. See `typed-dispatch-clear.log`, `typed-dispatch-live.log`, and their serialized dispatch records.

`pi-tmux-flow.py` ran the real Pi CLI and normal existing provider login as a primary on the lab's private tmux socket, with a 120-by-40 grid. A real persisted captain outcome triggered native processing. The first automatic response remained visible; the repeated automatic final became empty while keeping positive usage, and a fresh human response remained visible. The primary's actual transcript was exported by Pi itself as `native-pi-session.html` and rendered in an isolated browser for `native-pi-session.png`. The fork's real spend reader consumed that authentic transcript once despite repeated append requests, with recorded positive cost; see `measured-worker-spend.jsonl`.

Native Pi automatic watcher recovery remains untested. Both direct RPC probing and the runbook-compliant private tmux primary loaded the real extension and called its native arm tool. The tool initially reported an arm child, but the asynchronous native path subsequently exhausted five retries because its own FM_ROOT_OVERRIDE/FM_STATE_OVERRIDE exports defeat the marked-lab allowance. Unsetting inherited overrides does not change those internal exports. The real CLI watcher scenarios passed independently. Moving the checkout outside the gate or bypassing the guard is outside this phase's authority. Complete this specific scenario from an approved non-gate disposable checkout, or provide a supported adapter that retains the marked lab's stock path layout. See `pi-tmux-flow.log`; the exported session also shows the refusal. It is a setup boundary, not a newly introduced product failure.

All manual labs, private tmux servers, named Herdr sessions, owned Treehouse leases, fixture workers, isolated browser, and worktree scratch files were cleaned up. No permanent source/test changes were made. No full-suite, lint, push, PR or CI phase was executed here. The outer executor owns broad regression and delivery checks. Previously declined upstream R1 was left unchanged.
