# Teardown: task root span carries the recorded trace_link as an OTel span link

## Marked secondmate home
```console
$ grep -E "^(traceparent|trace_link)=" state/task-x1.meta
traceparent=00-11111111111111111111111111111112-3333333333333334-01
trace_link=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01
$ bin/fm-teardown.sh task-x1
teardown task-x1 complete (window firstmate:fm-task-x1, worktree /tmp/fm-teardown-tests.wjYq6T/ev-link/wt)
Backlog: task-x1 just finished (this home keeps no markdown backlog at /tmp/fm-teardown-tests.wjYq6T/ev-link/data/backlog.md). Update /tmp/fm-teardown-tests.wjYq6T/ev-link/data/backlog.md - move task-x1 to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.
exit=0
$ # OTLP body posted by the emitter (span only):
{
  "name": "firstmate.task",
  "traceId": "11111111111111111111111111111112",
  "spanId": "3333333333333334",
  "parentSpanId": null,
  "links": [
    {
      "traceId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab",
      "spanId": "bbbbbbbbbbbbbbbb"
    }
  ],
  "status": {
    "code": 1
  }
}
```

## Primary home, same meta (no marker): no link exported
```console
Backlog: task-x1 just finished (this home keeps no markdown backlog at /tmp/fm-teardown-tests.wjYq6T/ev-primary/data/backlog.md). Update /tmp/fm-teardown-tests.wjYq6T/ev-primary/data/backlog.md - move task-x1 to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.
exit=0
{"name":"firstmate.task","traceId":"11111111111111111111111111111112","links":"absent"}
```
