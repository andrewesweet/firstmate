# Local handoff: one firstmate.handoff span per moved key

```console
$ grep ^traceparent= state/design.meta   # secondmate agent carrier
traceparent=00-99999999999999999999999999999999-8888888888888888-01
$ bin/fm-backlog-handoff.sh design span-a span-b
handed off 2 item(s) to design: span-a span-b
  into /tmp/fm-backlog-handoff.YJY9lB/ev-sub/data/backlog.md
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the requested message WILL still be sent.
●  watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exit=0
$ # firstmate.handoff spans posted: 2
--- span 1
{
  "name": "firstmate.handoff",
  "traceId": "99999999999999999999999999999999",
  "parentSpanId": "8888888888888888",
  "attributes": {
    "firstmate.backlog.item": "span-a",
    "firstmate.route": "local"
  }
}
--- span 2
{
  "name": "firstmate.handoff",
  "traceId": "99999999999999999999999999999999",
  "parentSpanId": "8888888888888888",
  "attributes": {
    "firstmate.backlog.item": "span-b",
    "firstmate.route": "local"
  }
}
--- resource attributes of span 1
{"service.name":"firstmate","firstmate.task.id":"design","firstmate.home":"/tmp/fm-backlog-handoff.YJY9lB/ev-main","firstmate.task.kind":"secondmate","firstmate.secondmate.id":"design","firstmate.harness":"claude"}
```

## Default-off home: same handoff, no span
```console
handed off 1 item(s) to design: off-a
$ # firstmate.handoff spans posted: 0
```
