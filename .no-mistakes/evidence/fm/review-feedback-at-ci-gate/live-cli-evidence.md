# Generated CI-feedback instructions: live CLI evidence

Oracle: the supplied user intent and accepted follow-up decisions. The real fm-brief.sh command generated every brief in an isolated home. Assertions inspect the generated public instruction contract. No model interpretation or pipeline actions were exercised.

Plausible regressions rejected: checks-only polling; omitted inline feedback; premature done; lost pipeline fixes after green; incorrect Forgejo routes; default-only pause verb; CI-wait resolution closing a separate review decision; CI guidance leaking into local-only delivery.

## github-ci-feedback

CLI invocation: `bin/fm-brief.sh github-ci-feedback disposable-project --mode no-mistakes`

At the CI gate, poll about once a minute with one poll per command, and never put a single wait longer than your harness's command bound into one command.
Every poll reads the PR itself, not only its checks: `gh-axi pr checks <n>`, then the PR's review submissions, inline review comments, and issue comments with `gh-axi pr view <n> --comments --reviews`.
A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change is work for the gate, never a non-required check to dismiss: when `no-mistakes axi status` shows a parked gate, feed each item to it with `no-mistakes axi respond --action fix`, adding any finding the gate does not list yet as `no-mistakes axi respond --help` describes, and let the fix round commit and push.
When review feedback arrives and `no-mistakes axi status` shows no parked gate, escalate it inline in a keyed status line - append `needs-decision [at=<epoch>] [key=pr-<n>-<comment-id>]: review feedback: {comment URL} {what it asks for}` - then, for this decision only in place of rule 6's stop, keep polling about once a minute and wait for firstmate's reply instead of stopping, processing and acknowledging your Firstmate instruction inbox on each poll as that section describes, since the reply arrives there; on dismiss, reply on the PR; on fix, feed it to the next parked gate or CI-ready decision point as above when one comes, and when the run reaches CI green or its final outcome first, bring this branch up to the run's pushed head first by following `branch_sync.next_action` from `no-mistakes axi status` and running the `no-mistakes axi sync` command it prints when it names one (an already synchronized branch needs none), then commit it as post-pipeline follow-up work on top of this same branch so every pipeline fix commit remains present, then drive a new `no-mistakes` run with the same `--intent` to its outcome before `done:`.
Before appending `done:`, re-read the PR's reviews and comments and route any unactioned feedback through those paths first; never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered.
A wait only a maintainer can clear - GitHub's fork-workflow approval (`action_required` with no job run) or a rerun of a flaky job - is an external wait under rule 4, not a blocker: append `paused [at=<epoch>] [key=nm-<run>-ci-wait]: <what must happen>`, re-append that same keyed line after any later status event of your own while the wait is still open (a review-feedback `needs-decision` or its `resolved` line), keep polling, and when it clears append `resolved [at=<epoch>] [key=nm-<run>-ci-wait]: <how it cleared>` yourself and continue; never report it as `blocked:` and never stop on it.



## forgejo-ci-feedback

CLI invocation: `bin/fm-brief.sh forgejo-ci-feedback disposable-project --mode no-mistakes --forge forgejo`

At the CI gate, poll about once a minute with one poll per command, and never put a single wait longer than your harness's command bound into one command.
Every poll reads the PR itself, not only its checks: `tea api --repo <owner>/<repo> /repos/{owner}/{repo}/pulls/<n>` for `head.sha`, then `tea api --repo <owner>/<repo> /repos/{owner}/{repo}/commits/<head.sha>/status` for the checks; read the review submissions and comments with `tea api --repo <owner>/<repo> /repos/{owner}/{repo}/pulls/<n>/reviews`, `tea api --repo <owner>/<repo> /repos/{owner}/{repo}/pulls/<n>/reviews/<review-id>/comments` for each review, and `tea api --repo <owner>/<repo> /repos/{owner}/{repo}/issues/<n>/comments`, reading every page of these API lists and commit statuses.
A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change is work for the gate, never a non-required check to dismiss: when `no-mistakes axi status` shows a parked gate, feed each item to it with `no-mistakes axi respond --action fix`, adding any finding the gate does not list yet as `no-mistakes axi respond --help` describes, and let the fix round commit and push.
When review feedback arrives and `no-mistakes axi status` shows no parked gate, escalate it inline in a keyed status line - append `needs-decision [at=<epoch>] [key=pr-<n>-<comment-id>]: review feedback: {comment URL} {what it asks for}` - then, for this decision only in place of rule 6's stop, keep polling about once a minute and wait for firstmate's reply instead of stopping, processing and acknowledging your Firstmate instruction inbox on each poll as that section describes, since the reply arrives there; on dismiss, reply on the PR; on fix, feed it to the next parked gate or CI-ready decision point as above when one comes, and when the run reaches CI green or its final outcome first, bring this branch up to the run's pushed head first by following `branch_sync.next_action` from `no-mistakes axi status` and running the `no-mistakes axi sync` command it prints when it names one (an already synchronized branch needs none), then commit it as post-pipeline follow-up work on top of this same branch so every pipeline fix commit remains present, then drive a new `no-mistakes` run with the same `--intent` to its outcome before `done:`.
Before appending `done:`, re-read the PR's reviews and comments and route any unactioned feedback through those paths first; never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered.
A wait only a maintainer can clear - GitHub's fork-workflow approval (`action_required` with no job run) or a rerun of a flaky job - is an external wait under rule 4, not a blocker: append `paused [at=<epoch>] [key=nm-<run>-ci-wait]: <what must happen>`, re-append that same keyed line after any later status event of your own while the wait is still open (a review-feedback `needs-decision` or its `resolved` line), keep polling, and when it clears append `resolved [at=<epoch>] [key=nm-<run>-ci-wait]: <how it cleared>` yourself and continue; never report it as `blocked:` and never stop on it.



## holding-ci-feedback

CLI invocation: `bin/fm-brief.sh holding-ci-feedback disposable-project --mode no-mistakes`

At the CI gate, poll about once a minute with one poll per command, and never put a single wait longer than your harness's command bound into one command.
Every poll reads the PR itself, not only its checks: `gh-axi pr checks <n>`, then the PR's review submissions, inline review comments, and issue comments with `gh-axi pr view <n> --comments --reviews`.
A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change is work for the gate, never a non-required check to dismiss: when `no-mistakes axi status` shows a parked gate, feed each item to it with `no-mistakes axi respond --action fix`, adding any finding the gate does not list yet as `no-mistakes axi respond --help` describes, and let the fix round commit and push.
When review feedback arrives and `no-mistakes axi status` shows no parked gate, escalate it inline in a keyed status line - append `needs-decision [at=<epoch>] [key=pr-<n>-<comment-id>]: review feedback: {comment URL} {what it asks for}` - then, for this decision only in place of rule 6's stop, keep polling about once a minute and wait for firstmate's reply instead of stopping, processing and acknowledging your Firstmate instruction inbox on each poll as that section describes, since the reply arrives there; on dismiss, reply on the PR; on fix, feed it to the next parked gate or CI-ready decision point as above when one comes, and when the run reaches CI green or its final outcome first, bring this branch up to the run's pushed head first by following `branch_sync.next_action` from `no-mistakes axi status` and running the `no-mistakes axi sync` command it prints when it names one (an already synchronized branch needs none), then commit it as post-pipeline follow-up work on top of this same branch so every pipeline fix commit remains present, then drive a new `no-mistakes` run with the same `--intent` to its outcome before `done:`.
Before appending `done:`, re-read the PR's reviews and comments and route any unactioned feedback through those paths first; never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered.
A wait only a maintainer can clear - GitHub's fork-workflow approval (`action_required` with no job run) or a rerun of a flaky job - is an external wait under rule 4, not a blocker: append `holding [at=<epoch>] [key=nm-<run>-ci-wait]: <what must happen>`, re-append that same keyed line after any later status event of your own while the wait is still open (a review-feedback `needs-decision` or its `resolved` line), keep polling, and when it clears append `resolved [at=<epoch>] [key=nm-<run>-ci-wait]: <how it cleared>` yourself and continue; never report it as `blocked:` and never stop on it.



## direct-pr-boundary

CLI invocation: `bin/fm-brief.sh direct-pr-boundary disposable-project --mode direct-PR`

# Definition of done
Delivery contract: mode=direct-PR
Ship branch: fm/direct-pr-boundary
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi` that is ready for review, not a draft.
Before you report done, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {url}` to the status file and stop.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.


## local-only-boundary

CLI invocation: `bin/fm-brief.sh local-only-boundary disposable-project --mode local-only`

# Definition of done
Delivery contract: mode=local-only
Ship branch: fm/local-only-boundary
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/local-only-boundary`. Do NOT push, do NOT open a PR, do NOT merge.
A `done:` is accepted when the named head is on this project's shared local branch, not only on a detached copy; the check tests that head, not merely that a branch moved.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done [at=<epoch>]: ready in branch fm/local-only-boundary` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.


## gerrit-boundary

CLI invocation: `bin/fm-brief.sh gerrit-boundary disposable-project --mode no-mistakes --forge gerrit`

# Definition of done
Delivery contract: mode=no-mistakes forge=gerrit shape=squash
Ship branch: fm/gerrit-boundary
This project's review server is Gerrit: it has no pull requests and no forge CI the pipeline can watch, so **no-mistakes runs here as a review pass that ends at a ready branch**, and you then publish that branch as one change.
Pass `--skip push,pr,ci` on every `no-mistakes axi run` for this task, and skip nothing else: `review`, `test`, `document`, and `lint` are the whole point of the run.
Those three are the only steps that reach a forge, and skipping them is a supported outcome, not a degraded one.
The task is complete only when committed on your branch.
When you believe it is complete, append `done [at=<epoch>]: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate.
That first `done:` is the handoff that starts the pipeline; it is not a request to publish.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--int

## Real status-classifier output

```text
declared wait: holding [at=102] [key=nm-lab-ci-wait]: maintainer approves fork workflow
open decisions before clearing wait:
pr-42-9	needs-decision	review feedback: disposable comment asks for a changedeclared wait after clearing: 
open decisions after clearing wait:
pr-42-9	needs-decision	review feedback: disposable comment asks for a change
```
