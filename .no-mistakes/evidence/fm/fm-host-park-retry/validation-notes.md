# Targeted product validation

Oracle: the supplied author intent and recorded R1 decision. Explicit host exit 1 must notify immediately, despite healthy monitoring. Signal death and a clean host with no captured readiness must retry. Cursor repair follow-ups remain bounded.

## Real Claude Code 2.1.301, existing login

Two fresh marked lab homes were created inside the worktree with bin/fm-lab-home.sh. Each primary ran from the run worktree on its lab-only TMUX_TMPDIR with tmux -L fm-lab, at 160 by 45 cells. Product bin scripts were copied unchanged into each plain-checkout fixture to satisfy primary-root scope. The extra SessionStart hook acquired only the lab lock. An observing Stop hook called the real auto-arm. Faults replaced only external mktemp behavior; no harness, host, watcher, or login was faked. No model tools were permitted.

- Host startup failure: mktemp refused the real host's arm-capture file. The real host exited 1 before readiness. Auto-arm returned 2 after one attempt; Claude received the failure and replied FAILURE_RECEIVED. The first probe omitted the shared guard, causing subsequent empty follow-ups; removing the in-flight fixture ended those. The final healthy-watcher probe bounded itself by removing the task after its one result.
- Healthy monitoring: a real independent arm and watcher ran before the failure. The shared guard returned 0. Watcher health returned 0 both before and after the real host exited 1. Auto-arm still emitted the explicit failure after one attempt, and Claude replied HEALTHY_FAILURE_RECEIVED.
- Signal loss: the first host received SIGKILL at its first arm-capture request. A second real host started a real watcher. Appending a needs-decision status produced a real wake, and Claude replied TAKEOVER_RECEIVED.
- Clean output loss: the first auto-arm capture allocation failed, routing the real host's output to /dev/null. The real host closed normally. Auto-arm retried, captured the second host's wake, and Claude replied CLEAN_RETRY_RECEIVED.

The two retry probes used a minimal copied bin tree without the branch-dispatch dependencies, so attended eligibility safely passed the wakes to main. No engine or model behavior is claimed for those paths. They exercise the real host, watcher, auto-arm classification, and Claude delivery.

## Targeted behavioral checks

Both tests/fm-claude-stop-autoarm.test.sh and tests/fm-cursor-primary.test.sh completed successfully. A selected runner executed only the three host-hook write-failure cases, successfully. Their fake harness and stub engine make them supporting behavioral evidence, not live CLI proof.

The new Cursor healthy-successor test failed against the base guard with 'host failure 1 was hidden by the healthy successor' and passed against the target guard, including the three-follow-up budget. The control used the base guard in disposable fixtures; tracked files were unchanged.

## Limit and cleanup

Neither cursor-agent nor legacy agent is on PATH. The opt-in Cursor live test failed immediately with its explicit missing-binary diagnostic. The trusted runbook requires reporting this untested and forbids substituting a fake CLI or login. Supply an authenticated cursor-agent on PATH (or a repository-local FM_CURSOR_BIN) to complete Cursor live validation.

Only CLI hook behavior changed; native terminal transcripts record the user-facing output. No visual-layout change or screenshot is claimed. Both private tmux servers and lab homes were removed. The recorded independent watcher was confirmed no longer running. No repository-wide tests, lint, formatting, or other pipeline phases ran.
