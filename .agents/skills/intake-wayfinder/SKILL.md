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
`AGENTS.md` section 7 carries only the load trigger and the one rule that grilling never goes into a crew or secondmate brief; the rest of this procedure lives here.
It composes the installed Matt Pocock planning disciplines (`~/.agents/skills/`) with the fleet lifecycle: grill first, then route, then dispatch.
Nothing here authorizes implementation; maps plan and do not build.
Every map ticket, spec and ticket slice the fleet works is a tasks-axi row with its blocking edges, because tasks-axi is the fleet's system of record; a GitHub issue is only an additional mirror, used only when someone outside the fleet must read or answer it, and linked from its row.

Read the named Pocock skill files below as files.
Never brief a worker to run one as a skill: crews follow any discipline only by reading the named file, and firstmate sessions read them natively.

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
That routing picks `/wayfinder` (section 4), `/to-spec`, or `/to-tickets` (section 5), including straight to `/to-tickets` when a usable spec or plan already exists.
Their direct-`/implement` branches do not apply at the fleet: after the interview the pick is only `/wayfinder`, `/to-spec` or `/to-tickets`, because every slice the fleet works is published as tasks-axi rows.

## 4. Wayfinder maps, fleet-adapted

Name the destination first - the spec, decision, or change this effort is finding its way to - because the destination fixes the scope.
Read `~/.agents/skills/wayfinder/SKILL.md` as a file for the map shape (destination, notes, decisions-so-far index, not-yet-specified fog, out-of-scope) and the fog rules: ticket what is already sharp even if blocked, park the rest as fog, and graduate fog as the frontier advances.
Close a mis-scoped ticket instead of working it, recording a one-line out-of-scope reason and never `rm`-ing the row: a ticket held for the captain stays open until the captain's answer is recorded under `captain-hold-lifecycle`, a dispatched ticket is cleaned up under `AGENTS.md` section 7, and both apply when both hold; closing the row lifts its edge on the map row, so the map still clears.
Map ticket types to fleet work: `research` becomes a scout (agent-alone, parallel dispatches allowed, resolved by a cited report); `prototype` becomes a prototype scout reviewed with the captain over the existing crew-hosted board loop; `grilling` becomes a captain session with firstmate (never a briefed worker, per section 2); `task` becomes prerequisite work that unblocks a decision, dispatched as a scout or run as a precise captain checklist when it needs a human, never as a ship.
Record each ticket's blocking edges: the frontier is the `blocked_by` rows of `bin/fm-tasks-axi.sh show <map-id>` that also appear in `bin/fm-tasks-axi.sh ready`, because `ready` already excludes blocked and held rows while `blocked_by` scopes the list to this map, so the backlog-wide list alone is never the frontier; never resolve more than one ticket per session, research tickets excepted.
The map itself is an ordinary tasks-axi row whose body is the map index and which is blocked by each of its ticket rows, so it clears when its tickets do.
Maps plan and do not build: a cleared map merges into `/to-spec` and then `/to-tickets` before any implementation is dispatched, and never loops straight into implementation.

## 5. to-spec and to-tickets publication

Read `~/.agents/skills/to-spec/SKILL.md` for the spec shape (problem, solution, user stories, implementation and testing decisions, out of scope) and `~/.agents/skills/to-tickets/SKILL.md` for the slicing rules (tracer-bullet vertical slices, blocking edges, prefactor first, the expand-contract exception for wide refactors) as files.
Present the proposed breakdown to the captain as a numbered list with title, blockers, and end-to-end delivery per ticket, and iterate on granularity, edges, and merges until approved before publishing.
Work blockers first; a ticket is takeable when it appears in `bin/fm-tasks-axi.sh ready`, which excludes blocked and held rows.
