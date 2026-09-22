### route (label: the joined branch outcome verdict)
| variant | scored | raw agreement | policy agreement | confident disagreement | uncertain | unavailable |
|---|---|---|---|---|---|---|
| without_current_state | 0/0 | 0 (0.0%) | 0 (0.0%) | 0 | 0 (0.0%) | 1 |
unmatched (no outcome row carries this wake key; never counted as a verdict): full=4 without_current_state=1 without_pane_tail=1

### repeat control (full variant run twice on one wake; raw call agreement)
| question | full pairs | identical answers |
|---|---|---|
### cost (metered Jev usage the shim passed through; latency over every record, unavailable calls included)
| variant | records | with usage | input tokens total | output tokens total | latency p50 ms | latency p95 ms |
|---|---|---|---|---|---|---|
| full | 8 | 5 | 1357 | 142 | 5 | 30 |
| without_current_state | 2 | 1 | 300 | 30 | 40 | 50 |
| without_pane_tail | 1 | 1 | 1000000 | 123456 | 1000000 | 1000000 |
per granted wake (all variants of one wake key summed; records without a wake key excluded):
wake wk-1: input=600 output=60 records=5
wake wk-2: input=50 output=5 records=1
wake wk-3: input=1000000 output=123456 records=3
