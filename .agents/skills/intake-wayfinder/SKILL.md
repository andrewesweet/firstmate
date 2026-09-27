---
name: intake-wayfinder
description: >-
  Agent-only intake procedure for non-trivial work.
  Use before dispatching non-trivial work: grill the captain to confirmed shared understanding, then route with ask-matt to wayfinder vs to-spec vs to-tickets.
  This skill is the single owner of that procedure: what counts as non-trivial, the firstmate-adapted grilling rules, the routing decision, fleet-adapted wayfinder maps, and tasks-axi publication targets.
user-invocable: false
metadata:
  internal: true
---

# intake-wayfinder

This skill is the single owner of firstmate intake for non-trivial work.
`AGENTS.md` section 7 points here and does not restate this procedure.
It composes the installed Matt Pocock planning disciplines (`~/.agents/skills/`) with the fleet lifecycle: grill first, then route, then dispatch.
Nothing here authorizes implementation; maps plan and do not build.

Read the named Pocock skill files below as files.
They carry `disable-model-invocation: true`, so no crew reaches them through a Skill tool; crews follow any discipline only by reading the named file, and firstmate sessions read them natively.

## 1. What counts as non-trivial

Trivial asks stay fast with no ceremony: a clearly specified single action with no open design decisions, such as a typo fix, a version bump with a known target, one well-understood command, or relaying established evidence.
Non-trivial is everything else: a fuzzy plan, open decisions, multi-session scale, an irreversible, destructive, or security-sensitive surface, or genuine uncertainty about whether or what to build.
When the line is unclear, ask one concise question rather than guessing; a wrong fast dispatch costs a re-scope steer mid-validation, which is the most expensive intake failure.

## 2. Grilling, firstmate-adapted

Read `~/.agents/skills/grilling/SKILL.md` and `~/.agents/skills/domain-modeling/SKILL.md` as files; the one-line `grill-with-docs` wrapper only names this pair.
Map the ask as a design tree and work it in rounds: each captain-facing message asks exactly one whole frontier round, every question numbered with a recommended answer, then wait for the answers before the next round.
A question whose answer depends on another still-open question belongs to a later round, not this one.
Facts are firstmate's job: look them up in the registry, work under way, project code, or README, or dispatch a reading-legwork scout without blocking the rest of the frontier; never ask the captain for anything lookable-up.
Decisions are the captain's: put each to them with a recommendation and wait.
Sharpen domain language as you go: challenge terms that conflict with established vocabulary, split overloaded words with concrete edge scenarios, and cross-reference claims against code; record resolved terms in the brief and task note, never in a project `CONTEXT.md`, which is a project write needing concrete per-task captain approval.
The interview ends only at confirmed shared understanding: every frontier branch visited, nothing silently assumed, and the captain confirms.
In a secondmate home the captain is reached only through the parent channel, so a secondmate never grills on its own authority: it routes open decisions up through its marked return channel, and the grilling conversation happens at the main firstmate.
Grilling is a conversation with the captain and never goes into a crew or secondmate brief, because those workers have no human to question; a briefed worker "grilling" would answer its own questions, which breaks the human-in-the-loop contract by definition.

## 3. Route with ask-matt

Read `~/.agents/skills/ask-matt/SKILL.md` and its `PHASE-BOUNDARIES.md` as files and apply their routing, not their publication targets.
When the effort is foggy and more than one agent session can hold, start with `/wayfinder` (section 4).
When the grilled idea fits in one session, go straight to `/to-spec` and then `/to-tickets` (section 5), or to a single briefed ship or scout when the work turned out genuinely small.
When a runnable question blocks the plan - how a state model feels, which UI direction reads right - take the prototype detour first and fold its verdict back into the thread before speccing.
Keep grilling, spec, and tickets in one unbroken context where the window allows, so the spec builds on the verbatim reasoning rather than a flattened summary.

## 4. Wayfinder maps, fleet-adapted

Use a map only when the way from here to the destination is not yet visible and the effort exceeds one session; a well-scoped feature never needs one.
Name the destination first - the spec, decision, or change this effort is finding its way to - because the destination fixes the scope.
Read `~/.agents/skills/wayfinder/SKILL.md` as a file for the map shape (destination, notes, decisions-so-far index, not-yet-specified fog, out-of-scope) and the fog rules: ticket what is already sharp even if blocked, park the rest as fog, graduate fog as the frontier advances, and close mis-scoped tickets with a one-line out-of-scope record instead of resolving them.
Map ticket types to fleet work: `research` becomes a scout (agent-alone, parallel dispatches allowed, resolved by a cited report); `prototype` becomes a prototype scout reviewed with the captain over the existing crew-hosted board loop; `grilling` becomes a captain session with firstmate (never a briefed worker, per section 2); `task` becomes a ship or unblocking chore, the one type that does rather than decides, earning its place only by unblocking a decision.
Every ticket the fleet works is a tasks-axi row with its blocking edges recorded via tasks-axi block/unblock, so the frontier is simply the open unblocked rows; resolve at most one decision ticket per session, except parallel research scouts at charting time.
The map lives as tasks-axi rows plus the epic task's note as the index by default, and on GitHub issues only when someone outside the fleet must read or answer it.
Maps plan and do not build: a cleared map merges into `/to-spec` and then `/to-tickets` before any implementation is dispatched, and never loops straight into implementation.

## 5. to-spec and to-tickets publication

Read `~/.agents/skills/to-spec/SKILL.md` for the spec shape (problem, solution, user stories, implementation and testing decisions, out of scope) and `~/.agents/skills/to-tickets/SKILL.md` for the slicing rules (tracer-bullet vertical slices, blocking edges, prefactor first, the expand-contract exception for wide refactors) as files.
Publish into tasks-axi rows and brief content, not GitHub, unless the slice is outward-facing under the GitHub boundary the brief-shape work owns.
Present the proposed breakdown to the captain as a numbered list with title, blockers, and end-to-end delivery per ticket, and iterate on granularity, edges, and merges until approved before publishing.
Work blockers first; any ticket whose blockers are done is takeable.
