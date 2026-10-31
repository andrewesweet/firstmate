# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-24.04`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

Both hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers, with the later samples and platform exceptions below.
All artifact records were cross-checked against the corresponding job's markers.
This covered all 24 parallel and 201 serial members at that refresh; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

For the supervision-host suite's later serial timing samples and retained hint, see [Portable serial CI shards](#portable-serial-ci-shards).
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
The 2026-10-07 polytoken adapter tests carry provisional local measurements instead - 21090 ms for `tests/fm-polytoken-harness.test.sh` and the 103 ms live-guard skip for `tests/fm-polytoken-signals-live-e2e.test.sh`, both measured on the adapter-verification macOS host - because they postdate the 2026-09-30 baseline; a budget-permitted CI refresh must replace them with Ubuntu measurements (see [Portable serial CI shards](#portable-serial-ci-shards)).
The 2026-10-23 `tests/fm-approval-failover.test.sh` serial hint is a provisional local measurement of 5410 ms, the slowest of five local `bin/fm-test-run.sh` samples (4991-5410 ms), pending a budget-permitted Ubuntu timing-artifact maximum (see [Portable serial CI shards](#portable-serial-ci-shards)).
The 2026-10-23 Kimi folder-prompt live guard, `tests/fm-kimi-trust-prompt-live-e2e.test.sh`, carries a provisional 60 ms skip measured on the Linux host that recorded its captures, pending a budget-permitted Ubuntu measurement (see [Portable serial CI shards](#portable-serial-ci-shards)).
The 2026-10-26 `tests/fm-test-tap-verify.test.sh` serial hint is a provisional local measurement of 1000 ms, above a 238 ms `bin/fm-test-run.sh` sample on this Linux host, pending a budget-permitted Ubuntu timing-artifact maximum (see [Portable serial CI shards](#portable-serial-ci-shards)).
The wedge-cap suite carries the Ubuntu measurements from CI run [39597689178](https://github.com/kunchenguid/firstmate/actions/runs/39597689178) - 374225 ms for `tests/fm-watch-wedge-cap.test.sh` and the 74 ms live-guard skip for `tests/fm-watch-wedge-cap-live.test.sh` - in place of the provisional local measurements the suite first carried (1003000 ms and the 155 ms skip), which overstated the CI cost of both.
The same run measured the wedge-cap parity suite at 27763 ms, which `bin/fm-test-run.sh` packs at in place of the provisional 209000 ms local measurement.
`test_portable_serial_packing_budget_boundary` now pins every other fixture script to 1 ms, so packing exactly at the 1200000 ms budget is accepted and one millisecond above it is refused even when real serial members have no hint.
The coverage-guard test owns modeled real-hint headroom under that budget.
The session-start hint retains its pre-optimization maximum until CI measures the shorter fixture-only home-summary bound; do not discount a local speedup from CI packing weights.
The T3 Code backend suites carry the slowest successful Ubuntu samples from CI runs [39463576576](https://github.com/kunchenguid/firstmate/actions/runs/39463576576), [39814995718](https://github.com/kunchenguid/firstmate/actions/runs/39814995718), and [39883948163](https://github.com/kunchenguid/firstmate/actions/runs/39883948163) - 239245 ms for `tests/fm-backend-t3code.test.sh`, 57613 ms for `tests/fm-t3-mcp.test.sh`, 283 ms for `tests/fm-watch-inbox-meta.test.sh`, and the 51 ms and 52 ms live-guard skips for `tests/fm-backend-t3code-live-e2e.test.sh` and `tests/fm-backend-t3code-pr-tools-live-e2e.test.sh`.
`tests/fm-backend-t3code.test.sh` and `tests/fm-t3-mcp.test.sh` run in the portable parallel lanes, so those two values sit in `portable_parallel_weight_hints`: every case id the backend suite spawns carries a per-run suffix and its cleanup removes only the `/tmp/fm-<id>` directories that run created, and both suites passed running concurrently with each other and beside another parallel suite (see [`fm-test-isolation-proof.md`](fm-test-isolation-proof.md)).

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The serial hints were refreshed from successful per-script records in the `fm-test-timing-portable-serial-*` artifacts of the complete green [run 35279383618](https://github.com/kunchenguid/firstmate/actions/runs/35279383618) and the available completed shards of [run 35282466441](https://github.com/kunchenguid/firstmate/actions/runs/35282466441) on 2026-09-17.
Together these cover all 176 serial scripts at refresh time; retain the slower successful sample where both exist.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
An unfinished or failed invocation is not a healthy duration sample.
Hints that began as local measurements before their first green CI artifacts - the 2026-09-16 doubled `tests/fm-branch-claude-mod*.test.sh`, `tests/fm-branch-mod-bin.test.sh`, `tests/fm-precompact-skills.test.sh`, `tests/fm-promote.test.sh`, and `tests/fm-trace-span-lib.test.sh` values, the 2026-09-20 `tests/fm-branch-eligibility.test.sh` and `tests/fm-branch-report-sequence.test.sh` values, and the 2026-09-21 doubled `tests/fm-branch-{text,scope,routing,delivery,monitor,settlement}.test.sh` values - keep that local value where it still exceeds every green CI sample and otherwise moved to their CI maxima in the 2026-09-30 refresh below.
On 2026-09-30 the upstream merge pushed portable serial shard 5 past its 30-minute job cap while the other shards finished, because several merged scripts had outgrown their hints: `tests/fm-contributions.test.sh` measured 134885 ms against a 35676 ms hint, `tests/fm-branch-eligibility.test.sh` 5036 ms against 950 ms, and the 26 scripts the merge added, including `tests/fm-live-lab.test.sh` at 74859 ms, were packed on the default weight. The hints for those 87 scripts, and for every other script measured in the same local serial run of the whole lane, are local measurements from 2026-09-30, retained only where they exceed the CI-derived value; across the 36 scripts with both samples the local run totalled 1.11x the CI hints, so it neither replaced nor lowered the CI evidence.
On 2026-09-30 green main run [36705664426](https://github.com/andrewesweet/firstmate/actions/runs/36705664426) ran shard 4 in 22m15s while every shard modeled about 714 s, and [PR 85](https://github.com/andrewesweet/firstmate/pull/85) then lost two shard-4 runs to the same 30-minute cap, because measured CI durations had outgrown several hints since the 2026-09-17 refresh: `tests/fm-supervision-host.test.sh` reached 631801 ms against a 41512 ms hint and `tests/fm-watch-triage.test.sh` 1122548 ms against 697969 ms.
The hints were refreshed from the successful per-script records in the `fm-test-timing-portable-serial-*` artifacts of the six green main runs [36705664426](https://github.com/andrewesweet/firstmate/actions/runs/36705664426), [36671766731](https://github.com/andrewesweet/firstmate/actions/runs/36671766731), [36669112983](https://github.com/andrewesweet/firstmate/actions/runs/36669112983), [36576901412](https://github.com/andrewesweet/firstmate/actions/runs/36576901412), [36570391870](https://github.com/andrewesweet/firstmate/actions/runs/36570391870), and [36559467332](https://github.com/andrewesweet/firstmate/actions/runs/36559467332) on 2026-09-29 and 2026-09-30, whose nine shards all completed in every run; together they cover all 223 serial scripts, and every script keeps the slower of its earlier hint and its slowest completed CI sample, so no earlier evidence is lowered.
This PR's own green run [36753950591](https://github.com/andrewesweet/firstmate/actions/runs/36753950591) then measured `tests/fm-supervision-host.test.sh` at 1196951 ms against its 631801 ms six-run max while its shard-mates stayed at or under their hints, so the seventh sample moved it to a shard of its own and 47 scripts raised to their slower run samples.
On 2026-10-27 the upstream merge added 24 sleep-driven escalation tests to `tests/fm-watch-triage.test.sh`, and the green main runs [41133617493](https://github.com/andrewesweet/firstmate/actions/runs/41133617493), [41123153441](https://github.com/andrewesweet/firstmate/actions/runs/41123153441), [40597922313](https://github.com/andrewesweet/firstmate/actions/runs/40597922313), and [40456922206](https://github.com/andrewesweet/firstmate/actions/runs/40456922206) then measured that file at 1451-1735 s against its 1122548 ms hint, with its shard running to 96 percent of the 30-minute job cap.
The suite split on 2026-11-01: the wedge-threshold and guard, bounded unknown-alive, paused background-job recheck, recovery rearm, and exit-picker tests moved with their private fixtures into [`tests/fm-watch-triage-wedges.test.sh`](../tests/fm-watch-triage-wedges.test.sh).
Both halves stage watcher rounds through the shared case drivers in [`tests/watch-triage-helpers.sh`](../tests/watch-triage-helpers.sh); the classifier, absorb/no-verb, stale-core, heartbeat, and afk surfaces stayed in `tests/fm-watch-triage.test.sh` with every assertion preserved.
The same four runs refreshed every serial hint to its slowest successful sample where the packing budget allows.
`tests/fm-supervision-host.test.sh` moves to 802270 ms because its 1196951 ms figure was the 2026-10-07 outlier that fork commits c30a70c9 and c585cf20 fixed (four recent runs measure 525-802 s).
The split's proportional shares of the 1720747 ms whole-file sample are 1224829 ms for `tests/fm-watch-triage.test.sh` and 495918 ms for `tests/fm-watch-triage-wedges.test.sh`.
The remainder's share exceeds the 1200000 ms shard budget, so its hint is pinned at that cap and it schedules alone; its estimated 1225 s wall time leaves about 575 s of the 1800 s job cap.
The wedges hint carries the complementary 520747 ms (1720747 - 1200000), at or above its proportional share and its 504 s local measurement of the moved tests.
The three largest remaining growths kept current samples.
The lane's measured mass is about 13.26M ms against 12.0M ms of shard budget, so 168 smaller raises keep their earlier hints until the next capacity change; `serial_unhinted` drops from 29 to 0 because the same refresh measured the 29 previously default-weighted scripts.
The nine shared shards model within 0.2 percent of one another (1179784-1179825 ms), while the budget-pinned `tests/fm-watch-triage.test.sh` shard schedules alone at exactly 1200000 ms, about 1.7 percent above them.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Read the current shard count and modeled duration sums from that output after any suite or hint change; the [CI workflow](../.github/workflows/ci.yml) matrix must match the runner-owned count.
The 30-minute bound is a job timeout, so it covers [workflow setup](../.github/workflows/ci.yml) as well as shard execution.
Measure setup again when dependency installation changes before inferring job-level headroom from script hints.
This is a packing estimate, not measured new-workflow execution or an end-to-end latency guarantee.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R kunchenguid/firstmate --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns two canonical CI partitions, each attempting full source-aware ShellCheck analysis with one worker in CI (`--jobs 1`; local runs default to two bounded workers), pinned versions, workflow validation, and backend-purity checks.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The slowest portable serial shard sets the modeled longest path described in [Portable serial CI shards](#portable-serial-ci-shards).
Actual end-to-end latency also includes job setup and runner queue time, which these packing estimates do not bound.
A complete run under fifteen minutes therefore needs the heavyweight scripts to get faster or be split, which packing cannot do.
The [CI workflow](../.github/workflows/ci.yml) owns the job inventory; insufficient shared account capacity can erase the packing gain.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession, triggers only on pull_request events, and leaves the compliance workflow's event semantics unchanged.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
