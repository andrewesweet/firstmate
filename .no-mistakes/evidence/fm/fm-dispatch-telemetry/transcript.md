## clear
```
dispatch-resolve:
  status: clear
  model: jev-1.13.0   latency_ms: 7   tokens: 812/60
  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9
  probabilities: rule_1=0.01 rule_2=0.01 rule_3=0.01 rule_4=0.96 default=0.01
  note: rule matched
  note: 1 eligible candidate(s) unranked (kimi)
  candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible
  candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible
  candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty
  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'
exit=0
```
stderr: 
stdout identical to base 6840b2b: NO
3c3
<   model: jev-1.13.0   latency_ms: 5   tokens: 812/60
---
>   model: jev-1.13.0   latency_ms: 7   tokens: 812/60

## competing
```
dispatch-resolve:
  status: clear
  model: jev-1.13.0   latency_ms: 6   tokens: 812/60
  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.7
  probabilities: rule_1=0.40 rule_2=0.02 rule_3=0.02 rule_4=0.55 default=0.01
  note: rule matched
  note: 1 eligible candidate(s) unranked (kimi)
  candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible
  candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible
  candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty
  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'
exit=0
```
stderr: 
stdout identical to base 6840b2b: yes

## ambiguous
```
dispatch-resolve:
  status: ambiguous
  model: jev-1.13.0   latency_ms: 6   tokens: 812/60
  rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.5
  probabilities: rule_1=0.01 rule_2=0.01 rule_3=0.01 rule_4=0.96 default=0.01
  reason: confidence 0.5 below floor 0.6
  candidate: claude:sonnet  provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible
  candidate: cursor:cursor-grok-4.6-medium  provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset  -> eligible
  candidate: kimi:kimi-code/k3  provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty
exit=0
```
stderr: 
stdout identical to base 6840b2b: yes

## http500
```
dispatch-resolve:
  status: error
  reason: http 500 after 6 ms: {"error":"upstream"}
exit=0
```
stderr: dispatch-resolve: error (http 500 after 6 ms: {"error":"upstream"})
stdout identical to base 6840b2b: yes

## rule9
```
dispatch-resolve:
  status: error
  model: jev-1.13.0   latency_ms: 6   tokens: 812/60
  rule: rule_9 (No listed rule applies to this task.)   confidence: 0.9
  probabilities: rule_1=0.01 rule_2=0.01 rule_3=0.01 rule_4=0.96 default=0.01
  reason: rule rule_9 is not in the rules file
exit=0
```
stderr: 
stdout identical to base 6840b2b: NO
3c3
<   model: jev-1.13.0   latency_ms: 5   tokens: 812/60
---
>   model: jev-1.13.0   latency_ms: 6   tokens: 812/60

## transport
```
dispatch-resolve:
  status: error
  reason: http 000 after 5 ms: 
exit=0
```
stderr: jq: invalid JSON text passed to --argjson
Use jq --help for help with command-line options,
or see the jq manpage, or online docs  at https://jqlang.github.io/jq
dispatch-resolve: outcome log unwritable: /tmp/fmdr-live.VnvbHz/home/data/dispatch-resolve.jsonl
dispatch-resolve: error (http 000 after 5 ms: )
stdout identical to base 6840b2b: NO
3c3
<   reason: http 000 after 4 ms: 
---
>   reason: http 000 after 5 ms: 

