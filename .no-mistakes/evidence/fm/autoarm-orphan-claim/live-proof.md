# Live auto-arm claim validation
Executed real Claude Code 2.1.301, real Stop hooks, the real watcher and real turn-end guard from the target worktree. Each primary used a marked disposable FM_HOME and a private tmux socket with a 110 × 32 terminal. Existing login was used without credential changes. Tools and external integrations were disabled for these primaries.
## Healthy Stop and replacement session
| Observation | Claim generation | Claim owner | Session lock holder | Watcher |
|---|---:|---:|---:|---:|
| Before concurrent Stop | 1 | 1857702 | 1794609 | 1859398 |
| Concurrent Stop deferred | 1 | 1857702 | 1794609 | 1859398 |
| After old Claude was killed; replacement Stop | 2 | 2099347 | 2094426 | 1859398 |
| Replacement delivered wake; old hook exited | 2 | 2099347 | 2094426 | cycle closed |

The replacement retained the original watcher, changed the claim owner and generation, committed `outcome=rewake`, and returned exit 2. Real Claude then emitted `LAB_WAKE_ACK`. The superseded hook exited without emitting a wake banner.
```text
firstmate watcher wake - one supervision event needs a handling turn now.
check: ~/.no-mistakes/worktrees/d7dc7405a34e/01M54P4C0CEWF8GWG85R4BMWKB/.l/state/lab-wake.check.sh: orphan-takeover-live-event
Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.
```
## Resume with the same conversation ID
| Observation | Conversation ID | Lock holder | Claim owner | Watcher |
|---|---|---:|---:|---:|
| original-session-arming | 193a3c36-6733-415e-8388-c87551fa629a | 2238486 | 2241198 | 2242346 |
| dead-session-with-live-orphan-and-watcher | 193a3c36-6733-415e-8388-c87551fa629a | 2238486 | 2241198 | 2242346 |
| same-id-resume-superseded-orphan | 193a3c36-6733-415e-8388-c87551fa629a | 2243173 | 2249077 | 2242346 |
| resumed-Claude-received-wake | 193a3c36-6733-415e-8388-c87551fa629a | 2243173 | 2249077 | 2284269 |

The resumed Claude retained its predecessor’s conversation ID, acquired a different lock holder identity, superseded the surviving hook, attached to the same watcher, and received `same-id-resume-live-event` as asynchronous Stop-hook feedback.
## Guard boundaries under a real Claude Stop
The guard ran from a real Claude hook against disposable state copied from its live claim. There was no watcher in each probe state, so allowing the Stop depended on accepting the claim. Invalid claims had to produce the end-user repair banner. Identity mismatch was introduced in the serialized claim while retaining the live lock PID and session ID; no attempt was made to force kernel PID reuse.
| Case | Expected exit | Actual exit |
|---|---:|---:|
| legacy-with-ancestry | 0 | 0 |
| recycled-bridge-matching-session-and-holder-identity | 0 | 0 |
| missing-session-lock | 2 | 2 |
| malformed-session-lock | 2 | 2 |
| same-bare-pid-stale-holder-identity | 2 | 2 |
| missing-holder-identity | 2 | 2 |
| missing-session-sidecar | 2 | 2 |
| different-session-sidecar | 2 | 2 |
| legacy-broken-ancestry | 2 | 2 |
| pid-1-ancestry-remains-valid | 0 | 0 |

```text
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  TURN WOULD END BLIND - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher holds this home lock (last beat: 0s ago).
●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.
●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
## Supporting regression evidence
`tests/fm-claude-stop-autoarm.test.sh` and `tests/fm-turnend-guard.test.sh` passed at the target. The new orphan regression, executed against the base implementation, failed with the required contrast:

```text
not ok - the replacement session's first Stop must supersede the dead session's orphaned claim and rewake, not defer to it: expected exit 2, got 0
```
The initial interactive launch stopped at workspace trust. Stream mode exercised the existing login without changing trust configuration. Replacement launch initially hit a terminal hangup; keeping its parent shell alive resolved the launch. Initial controller timing errors were replaced by a separate successful same-ID resume run. Raw attempt logs are retained alongside the successful proofs.
All private lab servers were stopped. Remaining lab-owned watchers and the detached hook were terminated after checking their FM_HOME. Disposable lab directories and the temporary scope marker were removed. See `lab-cleanup.json`.

The full targeted `fm-watch-triage.test.sh` file completed successfully at both the target and base commits. The prior serial-1 failure did not reproduce. No linter, formatter, full repository suite, publication phase, or pipeline-control command was run.
