# Live evidence: ambient TRACEPARENT scrub on spawn

Both runs used a disposable lab FM_HOME (`bin/fm-lab-home.sh create`), a throwaway git project,
a real `bin/fm-spawn.sh --scout` spawn, a real tmux pane, and the real `claude` CLI as the worker.
The spawning environment carried the W3C spec example carrier
`00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01` in both runs.

## Trace context off (default) — `scout-off-pane.txt`

The pane sends `export GOTMPDIR=...`, `export COMPACT_ADVISER_DISABLE=1`, `export FM_TASK_ID=...`
and no `export TRACEPARENT=`. The worker probed its own process environment via `/proc/<pid>/environ`:

- tmux server (23244), pane `-bash` (23424), `treehouse get` (24085) and the launch shell (24300)
  all carry the ambient carrier `4bf92f35…-00f067aa…`.
- The launched `claude` worker (29260) has `TRACEPARENT` unset — the launch step dropped it.
- `state/sc-probe-1.meta` records no `traceparent=` line.

## Trace context on — `scout-on-pane.txt`

`config/trace-context` set to `on` and frozen by a real `bin/fm-session-start.sh`.

- The pane receives `export TRACEPARENT=00-2c8811365cb96ae16d533a3bd2077ecf-5d95a2c1a39f2094-01`.
- `state/sc-probe-3.meta` records the identical carrier.
- The worker's own `claude` process carries trace id `2c881136…` — the fresh per-task carrier, not
  the ambient `4bf92f35…`.

Both labs, their tmux servers, the throwaway project and its treehouse worktrees were removed in
the same turn.
