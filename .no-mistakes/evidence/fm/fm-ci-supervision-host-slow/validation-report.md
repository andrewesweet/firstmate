# Supervision-host cleanup validation

The changed file is `tests/fm-supervision-host.test.sh`. Production scripts and CI timeout settings have no diff between the supplied base and target.

The affected suite passed all 78 behavior cases with no gate skips. The canonical runner measured **699,326 ms (11m39s)** for the suite. Process sampling found no sustained activity from a home after its case registration was cleared, and no active fixture processes remained three seconds after exit.

## Before-and-after cleanup reproduction

Six unchanged behavior cases ran serially with the base and target versions of the test fixture. Temporary copies retained their original definitions and assertions; only their terminal dispatch lists were narrowed to these six cases. Each checkpoint waited 0.5 seconds after the case returned and inspected actual process state, limited to that run's fixture-home prefix. Zombie processes were excluded because they cannot poll. Session launchers, hosts, arms, watchers, and Stop hooks were counted as active helpers.

| Completed behavior case | Base active helpers / homes | Target active helpers / homes |
|---|---:|---:|
| `test_attended_routine_wake_is_handled_on_the_engine_and_stays_off_main` | 4 / 1 | 0 / 0 |
| `test_attended_captain_outcome_reaches_main_through_branch_outcomes` | 4 / 1 | 0 / 0 |
| `test_captain_leaving_mid_turn_keeps_its_captain_outcome_for_the_return` | 8 / 2 | 0 / 0 |
| `test_quiet_record_without_its_daemon_is_a_present_captain` | 10 / 3 | 0 / 0 |
| `test_claude_stop_hook_runs_the_host_without_the_file_and_off_opts_out` | 12 / 4 | 0 / 0 |
| `test_away_wake_is_handled_on_the_engine_and_never_reaches_main` | 13 / 4 | 0 / 0 |

The base retained ten active helpers across three completed fixture homes. The target retained zero helpers at every checkpoint. Both six-case invocations passed, and both had zero active helpers after exit. The runner measured 80,227 ms for base and 72,005 ms for target; these small local measurements include checkpoint pauses and do not characterize CI variance.

## Evidence and limits

- [Full suite transcript](supervision-host-suite.log) and [canonical timing artifact](supervision-host-timing.json).
- [Per-second process observations](supervision-host-processes.jsonl), [cleanup analysis](supervision-host-cleanup-analysis.json), and [post-exit observation](supervision-host-observation.json).
- [Cleanup checkpoints](cleanup-comparison.jsonl), [base transcript](cleanup-base.log), [target transcript](cleanup-target.log), and [comparison commands and timings](cleanup-comparison-summary.json).
- Reproduction drivers: [full-suite observer](observe-suite.py) and [matched-case comparison](benchmark-cleanup.py).

These are fixture behavior checks. They execute the real host, arm, watcher, store, and lease scripts with simulated session, backend, and engine dependencies. They are not live Claude-session evidence. This test-only change has no changed production interface to drive live. The outer CI phase must establish hosted job headroom and variance, including job setup; a local suite time cannot establish those values.

No source or intentional test changes were made in this Test phase. Generated test copies and scratch directories were removed. No production fleet session, credential, package, or tool configuration was modified.
