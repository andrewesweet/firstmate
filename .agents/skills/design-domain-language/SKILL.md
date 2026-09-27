---
name: design-domain-language
description: >-
  Agent-only design-session and retrospective procedure.
  Use when holding a design session with the captain, briefing a design scout, or running a retrospective that judges design.
  This skill is the single owner of that procedure: the codebase-design vocabulary, the domain-modeling discipline, and the gate on glossary and ADR writes.
user-invocable: false
metadata:
  internal: true
---

# design-domain-language

This skill is the single owner of how design sessions and retrospectives use Matt Pocock's design disciplines.
`AGENTS.md` section 7 points here and does not restate this procedure.
It composes the installed disciplines (`~/.agents/skills/`) with the fleet lifecycle: talk and briefs use the language everywhere, while glossary and decision writes stay gated.
Nothing here authorizes implementation; design proposes, ships dispose.

Read the named Pocock skill files below as files.
Crews reach every discipline the same way, by reading the named file; no crew invokes a user-invoked skill through a Skill tool, so wording briefed to crews always says read-as-file.

## 1. Design vocabulary, used exactly

Read `~/.agents/skills/codebase-design/SKILL.md` as a file and use its terms exactly: module, interface, depth, seam, adapter, leverage, locality.
Do not substitute component, service, API, or boundary; consistent language is the whole point.
Judge every design by its principles: depth lives at the interface, the deletion test decides whether a module earns its keep, the interface is the test surface, and one adapter means a hypothetical seam while two mean a real one.
When a deepening needs dependency handling, follow `DEEPENING.md` beside that file: classify each dependency, keep the seam discipline, and replace shallow-module unit tests with tests at the deepened interface instead of layering.
When one interface sketch is not enough, follow `DESIGN-IT-TWICE.md`: frame the constraints once, explore radically different interfaces in parallel, and compare on depth, locality, and seam placement before recommending.
Name modules with the project's domain words, not implementation handles.

## 2. Domain modeling: establish and refactor toward a ubiquitous language

Read `~/.agents/skills/domain-modeling/SKILL.md` as a file and work it as the active discipline, with the focus on establishing the domain model and refactoring toward it in its own language.
Challenge terms against the project's glossary the moment they conflict, sharpen fuzzy words into canonical terms, stress-test relationships with invented edge scenarios, and cross-reference claims against the code, surfacing contradictions as questions.
Propose refactorings that move the code toward the model: each proposal names the domain term it serves and the seam it deepens, in the vocabulary of section 1.
Intake grilling already sharpens language before dispatch; this skill owns the same discipline once design is under way (`intake-wayfinder` owns intake).

## 3. Design scouts

A design scout is briefed, never grilled: its Firstmate spec names the design question, points at the two files above as read-as-file, and asks for the vocabulary-judged options plus the domain terms each option serves.
Parallel interface exploration maps to parallel design scouts only when each scout owns a genuinely different interface direction; otherwise one scout compares.
The scout's verdict, proposed terms, and proposed refactorings land in `data/<id>/report.md`, never in the project.

## 4. Retrospectives

A retrospective that judges design reads the standing data sources (`docs/configuration.md` "Standing data sources for retrospectives") and judges in this same language: which modules proved shallow, where locality failed, which fuzzy term caused rework.
Frame each improvement as a deepening opportunity or a domain-language sharpening, with the evidence line that earned it.
The retro-trigger scout row is routed like any scout; its report carries the proposals.

## 5. Glossary and ADR writes stay gated

`CONTEXT.md` and `docs/adr/` writes happen only in repositories where per-repo setup of these skills is approved: new repositories and local forks, with each write enumerated as a captain-approved Firstmate-spec item (the setup rule itself lives with the per-repo setup work, not here).
Everywhere else, resolved terms and ADRs that pass the triple gate (hard to reverse, surprising without context, a real tradeoff) land as proposals in the report, formatted per `CONTEXT-FORMAT.md` and `ADR-FORMAT.md` beside the domain-modeling file so an approved repo can adopt them verbatim.
