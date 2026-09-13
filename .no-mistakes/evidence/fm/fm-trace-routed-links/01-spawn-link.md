# Scenario 1: routed task spawned inside a marked secondmate home

Ambient TRACEPARENT in the agent pane shell: `00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01`

```console
$ cat sm-home/.fm-secondmate-home
sm-routed
$ TRACEPARENT=$sm_tp bin/fm-spawn.sh routed-a-z1 <proj> --mode no-mistakes --yolo off
warning: /tmp/fm-trace-context-spawn.BGHzF0/ev/sm-home/data/routed-a-z1/launch-brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
spawned routed-a-z1 harness=claude kind=ship mode=no-mistakes yolo=off window=firstmate:fm-routed-a-z1 worktree=/tmp/fm-trace-context-spawn.BGHzF0/ev/wt-a
exit=0
$ grep -E "^(traceparent|trace_started|trace_link)=" sm-home/state/routed-a-z1.meta
traceparent=00-cc2cbb155a6862e4c36c4bb7372f8b7d-7f084add893a0965-01
trace_started=1789292119979
trace_link=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01
$ grep TRACEPARENT launch-a.log   # what the task pane actually receives
export TRACEPARENT=00-cc2cbb155a6862e4c36c4bb7372f8b7d-7f084add893a0965-01
```

Observed: fresh carrier (different trace id from the ambient value), ambient value recorded only as `trace_link=`, pane receives the fresh carrier.

## Relaunch keeps carrier and link
```console
$ TRACEPARENT=$sm_tp bin/fm-spawn.sh routed-a-z1 <proj> ...   # same id again (recovery relaunch)
spawned routed-a-z1 harness=claude kind=ship mode=no-mistakes yolo=off window=firstmate:fm-routed-a-z1 worktree=/tmp/fm-trace-context-spawn.BGHzF0/ev/wt-a
traceparent=00-cc2cbb155a6862e4c36c4bb7372f8b7d-7f084add893a0965-01
trace_link=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01
```

## Marker removed: relaunch drops the link (home now primary)
```console
$ rm sm-home/.fm-secondmate-home; TRACEPARENT=$sm_tp bin/fm-spawn.sh routed-a-z1 <proj> ...
spawned routed-a-z1 harness=claude kind=ship mode=no-mistakes yolo=off window=firstmate:fm-routed-a-z1 worktree=/tmp/fm-trace-context-spawn.BGHzF0/ev/wt-a
$ grep -E "^(traceparent|trace_link)=" sm-home/state/routed-a-z1.meta
traceparent=00-cc2cbb155a6862e4c36c4bb7372f8b7d-7f084add893a0965-01
(trace_link lines: 0)
```

# Scenario 2: primary home (no marker) under the same ambient TRACEPARENT
```console
$ ls primary-home/.fm-secondmate-home
.fm-secondmate-home': No such file or directory
$ TRACEPARENT=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01 bin/fm-spawn.sh ev-primary-z1 <proj> --mode no-mistakes --yolo off
spawned ev-primary-z1 harness=claude kind=ship mode=no-mistakes yolo=off window=firstmate:fm-ev-primary-z1 worktree=/tmp/fm-trace-context-spawn.BGHzF0/ev-primary/wt
$ grep -E '^(traceparent|trace_link)=' state/ev-primary-z1.meta
traceparent=00-c29e8d343057b0af0857132200454b35-c5d68cbc28ed1cc1-01
(trace_link lines: 0)
```

# Scenario 3: default-off home (no config/trace-context)
```console
spawned ev-off-z1 harness=claude kind=ship mode=no-mistakes yolo=off window=firstmate:fm-ev-off-z1 worktree=/tmp/fm-trace-context-spawn.BGHzF0/ev-off/wt
$ grep -cE '^(traceparent|trace_link)=' state/ev-off-z1.meta
0
$ span posts recorded: 0
```
