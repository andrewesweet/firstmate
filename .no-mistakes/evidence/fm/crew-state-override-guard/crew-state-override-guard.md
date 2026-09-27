# Live fm-crew-state.sh override-guard transcript

Real bin/fm-crew-state.sh driven against a real state directory, a real git
worktree, and a real tmux pane on an isolated TMUX_TMPDIR server.
Task feat-live's own status log says 'working:'. The other task's captured
generation (feat-other.*) says 'blocked:' and names a torn-down worktree.
feat-live's own snapshot capture (snapshot/feat-live.*) says 'paused:'.

## A - no override (control)
state: working · source: status-log · live crew is working

## B - leaked foreign override FM_CREW_STATE_*_OVERRIDE=.../feat-other.*
fixed script:
state: working · source: status-log · live crew is working
pre-fix script (base fba81cb):
state: unknown · source: none · worktree gone (torn down?)

## C - the task own snapshot override .../snapshot/feat-live.*
state: paused · source: status-log · snapshot captured paused state

## D - bare basename override, no directory component (cwd = snapshot dir)
state: paused · source: status-log · snapshot captured paused state

## E - adversarial suffix-only lookalike .../xfeat-live.* (foreign content)
fixed script:
state: working · source: status-log · live crew is working
pre-fix script (base fba81cb):
state: unknown · source: none · worktree gone (torn down?)
