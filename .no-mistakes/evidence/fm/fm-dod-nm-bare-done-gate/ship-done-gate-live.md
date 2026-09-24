# Live drive: fm-crew-state.sh ship done gate (branch fm/fm-dod-nm-bare-done-gate)

Each case is a real git worker copy plus a real state/<id>.meta, .status and
armed idle busy record, read by bin/fm-crew-state.sh. tmux runs on an isolated
socket (`tmux -L fm-lab-gate`) via a PATH shim, so no live fleet pane is touched.

## After the change (target commit f9e07b9)

    A no-mistakes, bare "done: implementation complete", head only in worker copy
    state: blocked · source: status-log · named head 39e96faa8ac674565b81f3f506aeb1f3f7b6b41a is unreachable outside the worker copy

    B empty mode (no mode= in meta), same bare done
    state: blocked · source: status-log · named head 39e96faa8ac674565b81f3f506aeb1f3f7b6b41a is unreachable outside the worker copy

    C no-mistakes, "done: PR https://github.com/o/r/pull/9 checks green", head pushed to origin
    state: done · source: status-log · PR https://github.com/o/r/pull/9 checks green

    D adversarial: confident bare done with no CI claim, "done: pushed everything, all good"
    state: blocked · source: status-log · named head 852b4a474b0b3f771ef947976da233a9d2f605b4 is unreachable outside the worker copy

    E adversarial: "done: PR https://github.com/o/r/pull/11 published for review" (non-Gerrit URL)
    state: blocked · source: status-log · the published-for-review report does not name a Gerrit change in the canonical https://<host>/c/<project>/+/<number> form

## Before the change (same cases A and B, bin/fm-dod-lib.sh from base c8e6080)

    A state: done · source: status-log · implementation complete
    B state: done · source: status-log · implementation complete

The unvalidated ship closed as done at the base commit and reads blocked after
the change, for both no-mistakes and empty mode.
