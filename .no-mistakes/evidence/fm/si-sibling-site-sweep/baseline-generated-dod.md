# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/baseline
The task is complete only when committed on your branch.

Implement by following the discipline at `~/.agents/skills/implement/SKILL.md`, read as a file: those skills are user-invoked, so read them instead of invoking them through a Skill tool.
Test first with the discipline at `~/.agents/skills/tdd/SKILL.md` at the seams this brief agrees.
Before committing, prove a diff you do not fully trust: name the one fact the change is safe because of and prove it by running the real code (a small script calling the real code), citing the run, or mark the diff unproven.
Before committing a behaviour-preserving change, pin current behaviour first with a characterisation test, snapshot, or equivalence harness - structure moves only after the pin, and type checks and lint are not a pin.
Before committing a bug fix, reproduce the bug on the surface where it was reported, verify the fix on that same surface, and commit the failing reproduction before the fix.
Run typechecking regularly, single test files regularly, and the full test suite once at the end.
Then self-review by following both axes at `~/.agents/skills/code-review/SKILL.md` - Standards (this repository's documented standards) and Spec (faithful implementation of this brief) - and fix what you find before committing to your `fm/baseline` branch.
In that self-review, check each test with the undefined-imports test before committing: if the test would still pass when every imported function returned undefined, rewrite the assertion or delete it.
Commit to `fm/baseline` only: never main, and never push outside this mode's delivery path.
On this no-mistakes ship, complete everything above before starting validation; once the run starts the pipeline owns every fix, so never hand-edit during a run and never run a second review beside it. A gap you spot that a parked gate does not list enters as an added finding, as `no-mistakes axi respond --help` describes.

When your implementation is committed, rebase onto the current default branch, then start /no-mistakes yourself to validate and ship a PR; do not append `done:` and wait for firstmate's instruction.

Before starting a run, claim a validation slot under this host's concurrent-validation cap: run `~/.no-mistakes/worktrees/feb37d45d9da/01M57NE6801MN1TQQ2G3XTE3P0/.sibling-sweep-live-cb964jg8/fm-nm-slot.sh no-mistakes axi run --intent "<the intent string>" --wait 10s`.
The script checks the host's counted validation count against the per-host limit (default 3, host-configurable) and runs the wrapped start only while a slot is free, holding the slot lock across that start so two workers cannot both squeeze in.
On exit 75 the host is at its limit: append one `paused [at=<epoch>]: validation slot full; waiting for a running validation to finish` line, retry on a bounded backoff (60s first, doubling to a 10m cap), and start the run the moment a retry passes.
On exit 78 the count or the limit could not be read: append `blocked [at=<epoch>]: {the script's exact error}` and stop.
Any other non-zero exit is the start command's own failure, not the slot gate: handle it exactly as the rules below describe.
Every command that starts a NEW run goes through the wrapper, including a later follow-up run on the same branch after a final outcome; drive, reattach, and `respond` calls on a run that already exists never claim a slot, so make them exactly as the rules below describe, without the wrapper.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Published intent` subsection body, not its heading, plus any later captain ask restated into that subsection.
That subsection is firstmate-authored at dispatch and is the only authorized source: pass it exactly as written, without speaker labels or direct address.
Keep `--intent` text in a worker-private file (created with `mktemp` or inside the task worktree), never in a fixed shared path.
Never include `## Captain's intent`, `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
If the brief has no `## Published intent` subsection, stop and ask firstmate to migrate the brief instead of starting no-mistakes; never substitute the captain's own words.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the published intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the terms the intent uses, not only the pointer; that substance is the intent by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Drive the run with ONE foreground `no-mistakes axi run` and let it block.
It bounds its own hold for you: `--wait` (default 8m) exists precisely so a harness with a ten-minute command cap gets a structured return instead of being killed mid-hold.
Declare that wait using the brief's status-reporting rule before the foreground drive call.
Never background a wait, and never arm a timer to stand in for one: a backgrounded call returns in milliseconds, so it does not wait at all, and every timer left behind fires later as a paid wake for nothing.
Only a drive call's return reports the green PR: `no-mistakes axi status` shows progress but never reports `checks-passed` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - that is not a failure: reattach at once by re-running `no-mistakes axi run` without flags, and issue the same foreground call again, one at a time, until a gate or outcome comes back; once checks are green it returns `checks-passed` immediately, and if it refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

At the CI gate, poll every 60 seconds with one poll per command, and never put a single wait longer than the ten-minute bound above into one command: `sleep 3000; gh pr checks <n>` is one blocking hold, not a poll.
Every poll reads the PR itself, not only its checks: `gh pr checks <n>`, then the PR's reviews, review comments, and issue comments (`gh api repos/<owner>/<repo>/pulls/<n>/reviews`, `.../pulls/<n>/comments`, and `.../issues/<n>/comments`).

A failing review-bot check, a review-bot finding, or a maintainer comment asking for a change is work for the gate, never a non-required check to dismiss: when `no-mistakes axi status` shows a parked gate, feed each item to it with `no-mistakes axi respond --action fix`, adding any finding the gate does not list yet as `no-mistakes axi respond --help` describes, and let the fix round commit and push.
When review feedback arrives and `no-mistakes axi status` shows no parked gate, write the comment's text and URL to `~/.no-mistakes/worktrees/feb37d45d9da/01M57NE6801MN1TQQ2G3XTE3P0/.sibling-sweep-live-cb964jg8/home/data/baseline/pr-<n>-<comment-id>.txt` and append `needs-decision [at=<epoch>] [key=pr-<n>-<comment-id>]: review feedback file=~/.no-mistakes/worktrees/feb37d45d9da/01M57NE6801MN1TQQ2G3XTE3P0/.sibling-sweep-live-cb964jg8/home/data/baseline/pr-<n>-<comment-id>.txt`, then keep polling every 60 seconds and wait for firstmate's reply instead of stopping; on dismiss, reply on the PR.
A firstmate fix answer is applied at the run's next stopping point, never mid-run: at a parked gate, through `no-mistakes axi respond --action fix --add-finding`; after the run's final outcome, as a follow-up commit on your existing branch plus a new /no-mistakes run on that same branch with the same `--intent`, started through the validation-slot wrapper like any other run start and driven to its outcome before `done:`.
Never hand-commit while a run is active and never start a second run while one is active.
Before appending `done:`, re-read the PR's reviews and comments and route any unactioned feedback through those paths first; never append `done:` while a `pr-<n>-<comment-id>` decision you opened is still unanswered.
A wait only a maintainer can clear - GitHub's fork-workflow approval (`action_required` with no job run) or a rerun of a flaky job - is an external wait under rule 4, not a blocker: append `paused [at=<epoch>] [key=nm-<run>-ci-wait]: <what must happen>` once, keep polling, and when it clears append `resolved [at=<epoch>] [key=nm-<run>-ci-wait]: <how it cleared>` yourself and continue; never report it as `blocked:` and never stop on it.
Gate findings marked ask-user still follow rule 6 exactly, even when they only describe that external wait: choosing to wait them out is answering them yourself.

When `gh pr checks <n>` shows every check passing or skipping (the two network-gated jobs skip by design), validation is done - that is the CI-ready return point, so do not wait for the pipeline to keep monitoring the merge in the background. Append `done [at=<epoch>]: PR {url} checks green` and stop. You are finished.
Before that done report, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
Before that done report, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
That CI-ready `done:` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
