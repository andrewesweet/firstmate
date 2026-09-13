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

## 2026-09-13 increment: the PR-ready and merged spans

Date: 2026-09-13.
Shell: GNU bash 5.2.21 (Linux).

The PR suite `tests/fm-pr-check-security.test.sh` gains three cases that drive the real scripts with a recording fake curl and assert the emitted OTLP JSON: a validated registration emits one `firstmate.pr.ready` span childing the task's recorded carrier with the canonical URL and forge head, each validated registration emits its own span, a rejected URL emits nothing, a disabled home emits nothing despite a recorded carrier, and a failed export leaves the `armed:` success line intact; a self merge emits one `firstmate.pr.merged` span with `origin=self` and `authority=attended` and its absorbed duplicate poll observation emits nothing; and poll-detected merges carry `origin=poll` with the persisted `yolo`, persisted `away-grant`, or `external` authority read the same way the ledger row reads it.

The merge suite `tests/fm-pr-merge.test.sh` gains two cases: a confirmed self merge emits exactly one `firstmate.pr.merged` span (the wrapper's own `pr=` recording emits the ready span) while a failed forge merge emits none, and a direct `fm_merge_outcome_report` drive proves one span for the first publication with nothing more from the already-recorded dedup return or a rejected origin.

```console
$ bash tests/fm-pr-check-security.test.sh > /dev/null; echo $?
0
$ bash tests/fm-pr-check-security.test.sh 2>&1 | tail -5
ok - post-rename poll validation faults revoke both names and allow a clean retry
ok - bootstrap does not rewrite unauthenticated checks or emit retired migration diagnostics
ok - watcher signals promptly stop custom checks and clean private state
ok - returned custom check descendants are drained on installed and fallback timeout paths
ok - teardown removes safe poll artifacts and refuses directory-shaped check files without traversal
$ bash tests/fm-pr-merge.test.sh 2>&1 | tail -2
ok - confirmed merges publish one merged span; failed merges publish none
ok - one merged span per published canonical outcome across self, poll, and dedup paths
```

Both suites exit 0; `tests/fm-pr-check-security.test.sh` and `tests/fm-pr-merge.test.sh` end with one `ok - ...` line per case rather than a footer, so check exit status and full output when refreshing this evidence.

## 2026-09-13 increment: the steer, promote, and control spans

Date: 2026-09-13.
Shell: GNU bash 5.2.21 (Linux).
Base: `main` at `4c9abf4`.

The emitter's span catalogue in [`bin/fm-trace-span-lib.sh`](../../bin/fm-trace-span-lib.sh)'s header grows its three lifecycle-owner entries, and each owner emits on its already-verified success path only, so a disabled home, an untraced task, or a failing emitter leaves every send, promotion, and control verb byte-identical in outcome:

- `bin/fm-send.sh` posts `firstmate.steer` immediately after positive delivery proof on each plane, before later fallible bookkeeping, carrying `firstmate.plane`, the durable record's `firstmate.inbox.seq` on local inbox sends, a marked request's `firstmate.corr`, the shell-native comma-joined `--resolve-key` keys as `firstmate.decision.key`, `firstmate.fire_and_forget=true`, and the validated `firstmate.delivery.id` on remote fire-and-forget sends; never the message content.
  Local and remote inbox emission remains inside the target metadata lock, so concurrent teardown cannot retire the carrier between proven delivery and emission.
- `bin/fm-promote.sh` posts `firstmate.promote` after the promoted record is published, carrying `firstmate.task.kind.prior=scout`, `firstmate.task.mode`, and `firstmate.task.yolo`.
- `bin/fm-control.sh` posts `firstmate.control` at the interrupt and exit verb dispatch sites immediately after the verified postcondition and before fallible success output, carrying the verb, the adapter-owned cancellation claim (`firstmate.control.confirmed`), the interrupt proof, and the exit result; the dispatch-site placement keeps a relaunch's internal stop from emitting, which the replacement launch's spawn span already covers.

The behavioral suites drive the real executables with the shared `tests/lib.sh` fake curl and OTLP parsers, and cover enabled, disabled, and emitter-failure paths plus the remote ownership boundary:

- `tests/fm-promote.test.sh` (new, 3 assertions): the published promotion posts exactly one span parenting on the task's carrier with the contract-flip attributes and the published `kind=ship` in the resource; a disabled home promotes identically and posts nothing; a refused collector cannot fail the promotion.
- `tests/fm-send-inbox.test.sh` (18 assertions, 6 new): a delivered inbox steer posts one span with the record sequence and no message content; a marked secondmate request's span carries its correlation id; fire-and-forget is flagged without its delivery id; a disabled home and a failing emitter leave the send untouched and release the identity lock; concurrent cleanup cannot retire metadata until the span reads its carrier; the typed and `--key` planes each post their own span.
- `tests/fm-send-resolve-key.test.sh` (22 assertions, 2 new): a delivered answer posts its span before later decision-close bookkeeping can fail, a two-key answer carries both keys comma-joined without answer text, a mistyped key refuses before delivery and posts no span, and failure of the former external formatting operation cannot change delivery, decision closure, or span attributes.
- `tests/fm-send-remote-delivery.test.sh` (17 assertions, 1 new): a remote secondmate steer's span is emitted by the parent home against the parent-owned carrier, with the correlation and no inbox sequence (the record's sequence lives in the remote home); a confirmed fire-and-forget span carries its validated delivery id while an unconfirmed attempt posts nothing; the remote leg posts no span.
- `tests/fm-control.test.sh` (39 assertions, 4 new): a verified interrupt posts one span with verb, cancellation claim (`confirmed=false` for Claude's acknowledgement-free adapter), and `agent-alive` proof; verified exits post `confirmed=true` with result `stopped` or `already-stopped`; a disabled home and a failing emitter leave the verb's outcome untouched; and a verified exit posts before a failed success-output write.
- `tests/fm-control-relaunch.test.sh` (54 assertions, 1 new): a traced relaunch posts exactly the replacement's `firstmate.spawn` span (`firstmate.relaunch=true`) and no control span.

```console
$ bin/fm-test-run.sh \
    tests/fm-promote.test.sh \
    tests/fm-send-inbox.test.sh \
    tests/fm-send-resolve-key.test.sh \
    tests/fm-send-remote-delivery.test.sh \
    tests/fm-control.test.sh \
    tests/fm-control-relaunch.test.sh \
    >/dev/null && printf '%s\n' 'lifecycle tracing suites passed'
lifecycle tracing suites passed
```

The runner preserves every selected suite's nonzero exit, so refresh this evidence through the same command without piping individual suite output.
The pre-existing suites that pin each owner's delivery, promotion, and control contracts pass unchanged, as do the earlier trace suites (`tests/fm-trace-span-lib.test.sh`, `tests/fm-trace-context-lib.test.sh`, `tests/fm-trace-context-spawn.test.sh`, `tests/fm-teardown.test.sh`, `tests/fm-remote-secondmate-trace-context.test.sh`).

## 2026-09-13 increment: the hold, reply, and wake spans complete the return path

Date: 2026-09-13.
Shell: GNU bash 5.2.21 (Linux).

The span catalogue owner (`bin/fm-trace-span-lib.sh`'s header) gains three return-path entries, each emitted only when its corresponding settlement or acknowledgement durably succeeds, and each silent for a task without a recorded carrier or a disabled home-session decision:

- `firstmate.hold` - `bin/fm-captain-hold.sh`, after a successful answer, release, or verified reconcile close is durably published, covering the recorded hold-set time through that settlement, with `firstmate.hold.close_mode` and a bounded `firstmate.hold.reason` read from the pre-close record because the close legitimately removes them.
- `firstmate.reply` - `bin/fm-pending-reply-lib.sh`, once per newly settled pending-reply record in the parent home, joining the second mate agent's trace through the parent's own meta, covering the confirmed delivery through the settlement, with `firstmate.corr` and `firstmate.reply.via`; an already-resolved replay posts nothing.
- `firstmate.wake` - `bin/fm-wake-drain.sh`, after the acknowledgement commit, per consumed queue row whose key maps to a home task through `fm_wake_status_key_map`, covering the row's queue time through the acknowledgement, with `firstmate.wake.kind`, `firstmate.wake.seq`, and `firstmate.wake.key`; heartbeats, per-poll check keys, and window-keyed stale rows emit nothing.

`tests/fm-captain-hold-lifecycle.test.sh` grows `test_close_paths_emit_hold_spans_over_the_recorded_hold_time` (51 `ok -` lines total): it drives the real hold, answer, `--release`, and `reconcile close` entrypoints against a real tasks-axi backend with a recording fake curl, asserting one span per close joined to the held task's own trace from the hold-set stamp with the close mode and reason, the idempotent answer replay posting again (the emitter keeps no dedup state), a taskless captain call and a refused answer posting nothing, a disabled session posting nothing, and the emitted reason bounded at 160 characters.

`tests/fm-pending-reply.test.sh` grows `test_settle_emits_parent_reply_span_once` (41 `ok -` lines total): the production settle path posts exactly one `firstmate.reply` span joining the second mate trace from the delivered epoch with the correlation and via, while an already-resolved replay, a disabled session, and a task without a recorded carrier post nothing.

`tests/fm-remote-reply.test.sh` extends the real fake-SSH remote chain (20 `ok -` lines, `ALL TESTS PASSED`): with the parent home's frozen decision on and the second mate's meta carrying its carrier, the settlement inside the runner's autohandle of a mirrored delta emits the reply span from the parent home - never the remote host - joined to the second mate's trace from the delivery time, with the correlation and `firstmate.reply.via=status`.

`tests/fm-wake-queue.test.sh` grows `test_acknowledgement_emits_task_keyed_wake_spans_only` (42 `ok -` lines total): one signal row for a traced task beside a window-keyed stale row, a taskless `startup-network` check row, and a heartbeat row; the acknowledgement posts exactly one `firstmate.wake` span parented on the task carrier starting at the row's queue time with kind, key, and seq, proving heartbeats and per-poll activity never emit.

```console
$ bash tests/fm-trace-span-lib.test.sh | tail -1
# all fm-trace-span-lib tests passed
$ bash tests/fm-captain-hold-lifecycle.test.sh | grep -c '^ok -'
51
$ bash tests/fm-pending-reply.test.sh | grep -c '^ok -'
41
$ bash tests/fm-remote-reply.test.sh | tail -1
ALL TESTS PASSED
$ bash tests/fm-wake-queue.test.sh | grep -c '^ok -'
42
$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

Counts describe the dated run above; rerun the suites to refresh evidence for the current revision.
The existing suites pass unchanged: the emitter unit suite (10 assertions), both spawn-path suites, teardown, and the other wake-drain suites, so the disabled-home byte-identical contract holds for the hold, answer, settle, and acknowledgement paths.
