Your scout task has been promoted to a ship task, mode=no-mistakes. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Read and route PR feedback before done.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-configured` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-configured --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=no-mistakes.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under `~/.no-mistakes/worktrees/0d094301c922/01M5NDG7A89JX5FJNB7V36WM66/.test-phase-tmp/fm-lab-promotion-configured/data/promote-configured/` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch. Never merge a PR.

The no-mistakes ask-user escalation below supersedes the scout rule 6 escalation shape.
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to `~/.no-mistakes/worktrees/0d094301c922/01M5NDG7A89JX5FJNB7V36WM66/.test-phase-tmp/fm-lab-promotion-configured/data/promote-configured/nm-<run>-findings.txt`, then report the gate with
   `needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=~/.no-mistakes/worktrees/0d094301c922/01M5NDG7A89JX5FJNB7V36WM66/.test-phase-tmp/fm-lab-promotion-configured/data/promote-configured/nm-<run>-findings.txt`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/promote-configured
The task is complete only when committed on your branch.
When you believe it is complete, append `done [at=<epoch>]: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
That first `done:` is the handoff that starts the pipeline, which owns the push; it is not a request to push from this copy.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked `[captain] `, excluding that metadata prefix; never copy its mixed `# Task` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Declare that wait using the brief's status-reporting rule before waiting on the backgrounded drive call.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
Only a drive call's return reports the green PR: `no-mistakes axi status` shows progress but never reports `checks-passed` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running `no-mistakes axi run` without flags, backgrounded the same way; once checks are green it returns `checks-passed` immediately, and if it refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

At the CI gate, poll about once a minute with one poll per command, and never put a single wait longer than your harness's command bound into one command.
Every poll reads the PR itself, not only its checks: `gh-axi pr checks <n>`, then the PR's review submissions, inline review comments, and issue comments with `gh-axi pr view <n> --comments --reviews`.
A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change is work for the gate, never a non-required check to dismiss: when `no-mistakes axi status` shows a parked gate, feed each item to it with `no-mistakes axi respond --action fix`, adding any finding the gate does not list yet as `no-mistakes axi respond --help` describes, and let the fix round commit and push.
When review feedback arrives and `no-mistakes axi status` shows no parked gate, escalate it inline in a keyed status line - append `needs-decision [at=<epoch>] [key=pr-<n>-<comment-id>]: review feedback: {comment URL} {what it asks for}` - then, for this decision only in place of rule 6's stop, keep polling about once a minute and wait for firstmate's reply instead of stopping, processing and acknowledging your Firstmate instruction inbox on each poll as that section describes, since the reply arrives there; on dismiss, reply on the PR; on fix, feed it to the next parked gate or CI-ready decision point as above when one comes, and when the run reaches CI green or its final outcome first, bring this branch up to the run's pushed head first by following `branch_sync.next_action` from `no-mistakes axi status` and running the `no-mistakes axi sync` command it prints when it names one (an already synchronized branch needs none), then commit it as post-pipeline follow-up work on top of this same branch so every pipeline fix commit remains present, then drive a new `no-mistakes` run with the same `--intent` to its outcome before `done:`.
Before appending `done:`, re-read the PR's reviews and comments and route any unactioned feedback through those paths first; never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered.
A wait only a maintainer can clear - GitHub's fork-workflow approval (`action_required` with no job run) or a rerun of a flaky job - is an external wait under rule 4, not a blocker: append `holding [at=<epoch>] [key=nm-<run>-ci-wait]: <what must happen>`, re-append that same keyed line after any later status event of your own while the wait is still open (a review-feedback `needs-decision` or its `resolved` line), keep polling, and when it clears append `resolved [at=<epoch>] [key=nm-<run>-ci-wait]: <how it cleared>` yourself and continue; never report it as `blocked:` and never stop on it.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {url} checks green` and stop. You are finished.
That CI-ready `done:` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
