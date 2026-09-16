# Live startup-context measurement (Claude Code 2.1.273, Pi 0.85.1)

Every run below is a real `claude -p` or `pi -p` session. Tool and MCP lists come from
Claude's stream-json `system/init` event; token totals are the first-call `result` usage
(input + cache_creation + cache_read). Model: haiku for Claude, zai/glm-5.3-flash for Pi.

## Claude crew launch (inline --settings from launch_template, empty temp project)

| | tools | MCP servers | skills | first-call input tokens |
|---|---|---|---|---|
| before (base inline settings) | 94 | ropey + 9 claude.ai connectors | 154 | 31,219 |
| after (trimmed inline settings) | 28 | ropey only | 139 | 23,600 |

Workflow, ReportFindings, ScheduleWakeup gone after; Task (Agent delegation) kept.
Bundled skills simplify, loop, workflow-authoring, update-config, run gone; caveman and no-mistakes kept.

## Claude primary session in the firstmate repo (tracked .claude/settings.json)

| | tools | MCP servers | skills | first-call input tokens |
|---|---|---|---|---|
| before (base commit tree) | 94 | ropey + 9 connectors | 158 | 50,482 |
| after (target commit worktree) | 28 | ropey only | 143 | 42,866 |

Task (Agent) still present in the worktree session: the tracked deny does not disarm delegation.

## Pi crew launch in the trusted firstmate worktree

| | tools reported by model | first-call input tokens |
|---|---|---|
| before | read, bash, edit, write, fm_branch_outcomes, fm_branch_processed, fm_watch_arm_pi | 27,554 |
| after (--exclude-tools) | read, bash, edit, write | 27,144 |

Delta 410 tokens, identical to the commit's 28,975 -> 28,565 measurement.
Same flag in a project without the extensions: exit 0, four built-in tools, no stderr (inert).
