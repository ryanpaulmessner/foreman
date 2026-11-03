---
id: fm-zgd.17.5
title: "Answers page: Saved answers, Your answers and Always rules tabs"
type: task
status: open
priority: 2
parent: fm-zgd.17
blocked_by: ["fm-zgd.17.1"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: null
close_reason: null
---

Spec: `docs/specs/question-cards.md` (approved 2026-11-03, card 63a4319f). Design pack: `docs/specs/question-cards.design.md`. Mockup: https://claude.ai/artifact/KkSwALbmBHC1TZg1vJf3jW (option C). The spec's Non-goals, Ask-first boundaries and copy apply to every ticket. Desktop only: 1440 and 820, light and dark.

## What to build
Spec Decisions 33-38 and 41.
- Tabs under the h1: Saved answers, Your answers, Always rules, each with its count; tab in the URL (`?tab=saved|yours|rules`). Tab machine `Foreman.Answers.Tab` (URL-driven). Generated docs page.
- Layout fixes (Decision 34): left-aligned 768 px column; one filter row (Search with icon, Repo select, Ticket) as `bb-filter-control`; Show archived as `bb-switch`, only on Saved answers.
- Saved answers compact rows with Copy link, Pin, Archive (Decision 35).
- Your answers (Decision 36): answered decision, UI review and batch cards, newest first; answer, note, ticket chip, "to <session name>", time; Search covers question, answer and note; 50 rows then "Show 50 more".
- Always rules (Decision 37) with Remove.
- Every state and copy in Decision 38.

## Interfaces
- Consumes the status line and copy field (shared fixes ticket).

## Design pack
State "Proposed: Answers tab"; Flows F5.

## Acceptance
- [ ] Three tabs with counts; filters have a visible border at 1440 and 820 in light and dark; Show archived only on Saved answers; Your answers lists answered decision cards newest first with answer and note; no row shows "user" as an actor (spec acceptance 12).
- [ ] LiveView tests for each tab and each Decision 38 state.
- [ ] verify ui before and after at 1440 and 820, light and dark.
