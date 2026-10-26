Live validation: Herdr task working directories and teardown

Herdr 0.9.5 and Treehouse 3.1.5 ran in disposable, worktree-local homes and pools. Every Herdr call used bin/fm-herdr-lab.sh and a named fm-lab-* session. The foreground viewer used the helper's fixed 40-row by 120-column pty. Worker payloads were real sleep processes; no model execution or credentials were needed.

The expected directory was the task metadata's worktree, never the primary project directory. The independent observations were Herdr pane foreground_cwd, Herdr process-info, Linux /proc/<shell-pid>/cwd, and persisted session.json. Flat, projected, flat replacement, and projected reclaim all restored into their recorded copies. Paths included spaces and an apostrophe.

A real attached viewer blocked projected teardown before reaping: the exact pane, top shell, foreground sleep process, metadata, presentation journal, and lease survived. After detach, teardown removed the endpoint and journal and returned its lease. Both normal claimed and legacy claimless slots completed cleanup. Real foreign-held leases refused teardown before endpoint close or lease mutation.

Refusal with prior task metadata returned the invocation's new lease while preserving the original record and lease. Fault injection after real Treehouse allocation (forwarded stdout, failing exit) proved the same rollback branch. Closing the real endpoint immediately before worktree entry proved refusal and lease return on failed delivery.

Close-boundary JSONL captures actual process-info before forwarded real pane-close calls. Session JSON files capture the running server's saved protocol state before restart. CLI/process and saved-state evidence are appropriate here: this change alters lifecycle behavior, not visual layout or copy.

Focused repository checks also covered both layouts, no project-directory sends, entry failure, ownership states, a still-parked validation refusal, unknown pane presence, focus-restoration warnings, journal retention, and unchanged non-Herdr abort/reap/remove order. These mocked-boundary regressions supplement the live scenarios; they are not counted as live proofs.

Initial evidence-driver assertions were corrected: active-tab refusal belongs to projected cleanup (flat kill preserves its existing close semantics); slot claims live beside the checkout; process lists are transient and excluded from lease identity comparisons; teardown returns the current recorded copy, not unrelated historical leases. Each corrected scenario was driven again. Earlier attempt logs are retained; round5-final-results.json selects the final verified outcomes.

All lab teardowns returned exit 0 and verified the live default-session tripwire. Disposable homes, pools, sessions, and test scratch directories were removed. No source changes were made.
