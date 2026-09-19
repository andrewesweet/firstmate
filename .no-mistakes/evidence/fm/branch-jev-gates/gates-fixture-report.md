# rows of bin/fm-branch-shadow-gates.sh output that tests/fm-branch-mod-bin.test.sh asserted verbatim over its 21-record fixture (grep -Fx echoes each matched line)
| absorb-no-new-outcome | 4 | 16 | 3 | 2 (66.7%) | 0 | 1 | 1 |
| absorb-routine-working | 2 | 18 | 2 | 1 (50.0%) | 0 | 1 | 0 |
| stale-active-suppress | 6 | 2 | 6 | 2 (33.3%) | 3 | 1 | 0 |
| pr-ready-arm | 4 | 16 | 2 | 1 (50.0%) | 1 | 0 | 0 |
| severity-alert | 2 | 18 | 1 | 0 (0.0%) | 1 | 0 | 1 |
| candidate-order | 3 | 0 | 3 | 2 (66.7%) | 0 | 1 | - |
unmatched (no outcome row carries this wake key; never counted as a verdict): 1 record
torn down (a task record is gone, so the merge-poll and stale-repair truth for these wakes is no longer readable): 1 record
| absorb-no-new-outcome | 0.96 | 0 | 0.0% |
| stale-active-suppress | 0.91 | 0 | 0.0% |
| pr-ready-arm | 0.70 | 2 | 50.0% |
| candidate-order | - | - | - |
1700:8	stale-active-suppress	loss	pane=fm-t4 window=1800s
1700:10	stale-active-suppress	delay	pane=fm-t5 window=1800s
1700:17	stale-active-suppress	correct	pane=fm-t7 window=1800s
1700:11	candidate-order	loss	candidates=t1:0.9,t2:0.5 first_reported=t2
1700:12	candidate-order	correct	candidates=t2:0.9,t1:0.5 first_reported=t2
1700:20	stale-active-suppress	delay	pane=fm-t2 window=1800s
ok - the gates scorer scores only full-variant records with facts, joins ground truth from outcomes, backstop surfacing, and derivable main actions, splits wrong fires into delay and loss, and sweeps for the lowest clean floor
