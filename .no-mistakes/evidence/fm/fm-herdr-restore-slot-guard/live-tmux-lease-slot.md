# Live drive: durable slot lease + pane survival (real treehouse v2.3.0, real tmux, private socket)

Spawn's endpoint line is now a child shell: `(cd -- '<leased copy>' && exec "${SHELL:-/bin/sh}")`.

    $ treehouse get --lease --lease-holder live-task
    Leased worktree at <pool>/project-b92fd1/1/project
    state: {"name":"1","leased":true,"lease_holder":"live-task"}

    # pane entered the copy in the child shell
    pane_current_path=<pool>/project-b92fd1/1/project

    # every process leaves the copy (Herdr-restart shape): pane shell cd /
    pane cwd now: /
    $ treehouse get --lease --lease-holder other-task
    -> <pool>/project-b92fd1/2/project     (slot 1 NOT reissued)

    # a return claiming the wrong holder refuses, slot stays leased
    $ treehouse return --force --if-lease-holder other-task <slot 1>
    failed to return worktree: lease precondition failed: lease holder does not match worktree <slot 1>
    state: {"name":"1","leased":true,"lease_holder":"live-task"}

    # teardown's return with the right holder, child shell sitting in the copy
    $ treehouse return --force --if-lease-holder live-task <slot 1>
    Terminated lingering processes: bash (1290624)
    Worktree returned to pool.
    pane alive: 1261707 bash dead=0        <- pane's own top-level shell survived
    pane cwd after teardown: /
    state: {"name":"1","leased":null,"lease_holder":null}
    dirty file present: no                 <- slot cleaned and reset
