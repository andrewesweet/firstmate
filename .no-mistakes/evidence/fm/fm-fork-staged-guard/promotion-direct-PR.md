Your scout task has been promoted to a ship task, mode=direct-PR. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Deliver the requested change on the selected fork.

## Published intent
Deliver the investigated change on the fork.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-direct-PR` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean copy of the base branch `release/1.2`, then create your branch: `git checkout -b fm/promote-direct-PR --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=direct-PR.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under `/home/cti/.no-mistakes/worktrees/f9a83591f83e/01M5Q76AW9BSCFW8MNGY4HGXG9/.fm-live-fork-uvmq5w4r/data/promote-direct-PR/` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the base branch `release/1.2` or the default branch (push only your `fm/promote-direct-PR` branch). Never merge a PR.

# Definition of done
Delivery contract: mode=direct-PR fork-staged=acme/widgets
Ship branch: fm/promote-direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.

Implement by following the discipline at `~/.agents/skills/implement/SKILL.md`, read as a file: those skills are user-invoked, so read them instead of invoking them through a Skill tool.
Test first with the discipline at `~/.agents/skills/tdd/SKILL.md` at the seams this brief agrees.
Before committing, prove a diff you do not fully trust: name the one fact the change is safe because of and prove it by running the real code (a small script calling the real code), citing the run, or mark the diff unproven.
Before committing a behaviour-preserving change, pin current behaviour first with a characterisation test, snapshot, or equivalence harness - structure moves only after the pin, and type checks and lint are not a pin.
Before committing a bug fix, reproduce the bug on the surface where it was reported, verify the fix on that same surface, and commit the failing reproduction before the fix.
Run typechecking regularly, single test files regularly, and the full test suite once at the end.
Then self-review by following both axes at `~/.agents/skills/code-review/SKILL.md` - Standards (this repository's documented standards) and Spec (faithful implementation of this brief) - and fix what you find before committing to your `fm/promote-direct-PR` branch.
In that self-review, check each test with the undefined-imports test before committing: if the test would still pass when every imported function returned undefined, rewrite the assertion or delete it.
Commit to `fm/promote-direct-PR` only: never main, and never push outside this mode's delivery path.

When it is implemented and committed, push your branch and open the PR on the fork `acme/widgets` with `gh pr create -R acme/widgets --base release/1.2 --head fm/promote-direct-PR`, ready for review, not a draft, against the base branch `release/1.2` (`--base release/1.2`), not the repository default.
Before you report done, read the PR back from the forge and confirm it is not a draft (`gh pr view <number> -R acme/widgets --json isDraft --jq .isDraft` must print `false`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh pr ready <number> -R acme/widgets`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {url}` to the status file and stop.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
