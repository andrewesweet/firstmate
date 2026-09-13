# Trace-context propagation verification

Repeatable evidence for the default-off native W3C trace-context capability.
Current behavior and rationale are owned by [`../trace-context.md`](../trace-context.md) and the configuration schema by [`../configuration.md`](../configuration.md) ("Trace context propagation"); this page records evidence only.

Date: 2026-08-03.
Shell: GNU bash 3.2.57 (macOS).
Comparison base: `main` at `976d97f`.

The colocated unit suite `tests/fm-trace-context-lib.test.sh` exercises validation (valid accepted; malformed, wrong-length, uppercase, all-zero, `ff` version, and shell-metacharacter values rejected), root minting with every mint a distinct sampled root and no parent-adoption input, the recovery reuse path with the recorded carrier winning over the ambient environment, default-off omission, the enable precedence of `FM_TRACE_CONTEXT` over `config/trace-context` with unset or empty deferring to the file, normalized home-session state, atomic replacement of a read-only prior record, stale-session rejection after failed publication, missing or invalid state defaulting off, the Secondmate home-session boundary with later file state plus the per-task trace boundary (two resolves under one persistent ambient `TRACEPARENT` root two distinct traces and adopt neither), forced entropy failure omitting safely, the minted-root fixed-shape check, the W3C Baggage percent encoder (safe set byte-wise; space, metacharacters, quote, and multi-byte characters escaped), the fixed resource-attribute key list and order rendered from a task meta (project basename encoded, home derived from the meta, an empty model rendered empty), `firstmate.secondmate.id` selected by task kind or the spawning home marker (the agent's own task id for a `kind=secondmate` meta, the spawning home's marker id for a routed task inside a secondmate home, absent in a main home), and absent or id-less meta rendering nothing while always returning success.

The spawn-path integration suite `tests/fm-trace-context-spawn.test.sh`, hermetic against an ambient `FM_TRACE_CONTEXT`, drives `bin/fm-spawn.sh` end to end with a fake tmux pane and a real isolated git worktree: enabled, one resolved carrier is recorded as `traceparent=` in the meta only after the identical `TRACEPARENT` export is sent before the launch literal; enabled, the pane also receives one `OTEL_RESOURCE_ATTRIBUTES` export sent immediately after `TRACEPARENT` and before the launch literal, matching the meta's join keys and preserving any pre-existing pane value as the comma prefix; disabled, neither the export nor any allowlist retention term appears and neither is written nor sent (`GOTMPDIR` still is); an allowlisted launch retains `OTEL_RESOURCE_ATTRIBUTES` beside `TRACEPARENT`; a failed carrier delivery leaves no `traceparent=` claim while the source task still launches; an unsafe delivery whose partial input cannot be cleared stops before appending the launch command; a failed metadata append removes the carrier from the launched task without aborting it; duplicate Secondmate preflight leaves inherited trace configuration unchanged; a relaunch reuses the recorded carrier verbatim; and spawns ignore later config and environment edits in favor of the frozen home-session decision.
The per-task boundary regression models the reviewed Secondmate scenario exactly: two unrelated tasks spawned sequentially from one home while the same fixed `TRACEPARENT` sits in the spawning environment (a persistent Secondmate's launch-time carrier) record and inject valid carriers whose trace ids differ from each other and from the ambient carrier, and a relaunch of the first task reuses its original carrier verbatim for both the meta record and the injected export.
Two further assertions drive a genuine two-level primary -> Secondmate -> worker chain, running `bin/fm-spawn.sh` twice with the exact environment the primary injects into the Secondmate, and prove the primary's effective override governs the nested worker both ways: env-on with no config file keeps the nested worker enabled while it roots its own per-task trace distinct from the Secondmate's carrier, and env-off with the file present keeps the nested worker disabled even though the `config/trace-context` file was copied into the Secondmate home.
A final assertion drives the file-decided path (`FM_TRACE_CONTEXT` unset) and proves the Secondmate's recorded/injected carrier and its delivered `FM_TRACE_CONTEXT=on|off` snapshot are always derived from one frozen decision, so a carrier is never paired with the opposite enable state.
The resource-attribute cases also execute the emitted pane commands through a real shell and child environment probe for enabled, disabled, and allowlisted launches.
The suite touches no real harness or live fleet.
`tests/fm-session-start.test.sh` additionally proves only a lock-owning session start writes the effective state and a lock-refused read-only start leaves it unchanged.

The remote-route suite `tests/fm-remote-secondmate-trace-context.test.sh` covers the Secondmate path that never reaches the local export site, driving the real chain - the parent's `bin/fm-spawn.sh`, `bin/fm-on.sh`, the real remote entrypoint, `bin/fm-remote-secondmate-control.sh`, and the remote host's own `bin/fm-spawn.sh` - over the deterministic SSH boundary with a stateful fake Herdr CLI, the backend a remote second mate always runs on, so the carrier the remote pane receives is read back from that pane's own log: disabled, the parent records no `traceparent=`, the remote pane receives no carrier or resource-attribute export, the remote home inherits no enablement flag, and the delivered snapshot is `FM_TRACE_CONTEXT=off` while `GOTMPDIR` still ships; enabled, the parent's recorded carrier, the remote endpoint's own record, and the exported pane value are one identical valid carrier sent after `GOTMPDIR` and before the launch command, the pane also receives the resource-attribute export rendered on the remote host with `firstmate.task.kind=secondmate`, its own task id as `firstmate.secondmate.id`, and the project basename, ordered after `TRACEPARENT` and before the launch command with the prefix-preserving form, with `FM_TRACE_CONTEXT=on` and the inherited flag delivered; a relaunch keeps that carrier verbatim in both the parent record and the pane export; a second remote route resolved from an environment holding a fixed ambient `TRACEPARENT` roots a trace id distinct from both that ambient carrier and the first route; the remote receiver accepts `config/trace-context` as ordinary declared inherited material while refusing `config/secondmate-harness`, which the primary deliberately does not propagate; and the delivery argument that carries a parent's carrier to a remote host is refused on a ship spawn, on a shell-metacharacter value, on an all-zero trace id, and on an empty value, so nothing but a strict W3C carrier on a Secondmate launch can reach a pane export.

```console
$ bash tests/fm-trace-context-lib.test.sh | tail -1
# fm-trace-context-lib.test.sh: all assertions passed
$ bash tests/fm-trace-context-spawn.test.sh | tail -1
# all fm-trace-context-spawn tests passed
$ bash tests/fm-remote-secondmate-trace-context.test.sh | tail -1
ALL TESTS PASSED
```

Run all three trace-context suites from the repo root; each prints one `ok - ...` per assertion.
A single live-backend end-to-end check - a real spawn confirming the pane received the `TRACEPARENT` export before the launch line, with nothing left after teardown - is a bounded manual step, deferred here because a live agent spawn disrupts a running fleet.

## Resource-attribute export evidence (PR 1)

Date: 2026-09-12.
Shell: GNU bash 5.2.21 (Linux).
The recorded run below predates the home-metadata correction, removal of source-inspection assertions, and child environment probe.
Its counts describe that run, not the current suites; rerun the commands above to refresh evidence for the current revision.

```console
$ bash tests/fm-trace-context-lib.test.sh | tail -1
# fm-trace-context-lib.test.sh: all assertions passed
$ bash tests/fm-trace-context-spawn.test.sh | tail -1
# all fm-trace-context-spawn tests passed
$ bash tests/fm-remote-secondmate-trace-context.test.sh | tail -1
ALL TESTS PASSED
$ bash tests/fm-trace-context-lib.test.sh | grep -c '^ok -'
30
$ bash tests/fm-trace-context-spawn.test.sh | grep -c '^ok -'
15
$ bash tests/fm-remote-secondmate-trace-context.test.sh | grep -c '^ok -'
6
```

## 2026-09-13 increment: the OTLP span emitter, the task root, and the spawn span

Date: 2026-09-13.
Shell: GNU bash 5.2.21 (Linux).

The colocated unit suite `tests/fm-trace-span-lib.test.sh` exercises the emitter through a fake curl that records its arguments and stdin body.
It checks omission for untraced tasks and disabled sessions, child and root span identities, timestamps, status mapping, endpoint precedence, and resource attributes decoded from the emitted OTLP JSON.
Collector refusal and timeout exit codes are exercised in a separate Bash process with errexit and pipefail enabled, asserting that execution continues silently.
Resource checks preserve spaces, punctuation, quotes, backslashes, Unicode, and tabs, and cover secondmate identity and absent metadata keys.

The spawn-path suite `tests/fm-trace-context-spawn.test.sh` grows two assertions (14 total): an enabled spawn records a numeric `trace_started=` beside the carrier, posts exactly one `firstmate.spawn` span parenting on the carrier with `firstmate.relaunch=false` and the meta's `spawn_gen`, and a formal `--relaunch` preserves both the carrier and the original mint time while posting `firstmate.relaunch=true` with `firstmate.spawn_gen.prior` naming the replaced generation; a disabled home posts nothing and records no `trace_started=`.
The existing twelve assertions, including the default-off byte-identical meta and pane contract, pass unchanged.

The teardown suite `tests/fm-teardown.test.sh` checks the task-root contract owned by [`fm-trace-span-lib.sh`](../../bin/fm-trace-span-lib.sh): recorded identity and start time, terminal outcome, final metadata attributes, forced teardown, and disabled emission.
Its `test_task_root_span_tagged_terminal_status` regression covers bracketed and unbracketed correlation tags, a final line without a newline, and later nonterminal events that must not replace the last terminal outcome.

The remote-route suite `tests/fm-remote-secondmate-trace-context.test.sh` (6 assertions) passes unchanged, proving a remote-routed second mate still launches end to end with the emitter library sourced on both hosts.

```console
$ bash tests/fm-trace-span-lib.test.sh | tail -1
# all fm-trace-span-lib tests passed
$ bash tests/fm-trace-context-lib.test.sh | tail -1
# fm-trace-context-lib.test.sh: all assertions passed
$ bash tests/fm-trace-context-spawn.test.sh | tail -1
# all fm-trace-context-spawn tests passed
$ bash tests/fm-teardown.test.sh | tail -1
ok - the run abort and the leaked-process reap both complete before the destructive worktree return
$ bash tests/fm-remote-secondmate-trace-context.test.sh | tail -2
ALL TESTS PASSED
```

`tests/fm-teardown.test.sh` ends with one `ok - ...` line rather than a footer; check the suite's exit status and complete output when refreshing this evidence.
