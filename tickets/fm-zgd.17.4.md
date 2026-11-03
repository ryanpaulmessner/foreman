---
id: fm-zgd.17.4
title: "Question cards: request drawer shows rows that open the card on Needs you"
type: task
status: open
priority: 2
parent: fm-zgd.17
blocked_by: ["fm-zgd.17.3"]
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
Spec Decision 27 (drawer behaviour: coordinator call, Needs you is the one place to answer).
- The drawer shows one stacked row per pending card: kind badge, source and age on one line, the question under it, "Open" at the right. Header: "Needs you", count badge, "Open full page", Close.
- A row click or Open goes to `/needs-you?card=<id>` with that card open and closes the drawer; on Needs you it patches the page.
- The drawer's own answer handler and its "Request not updated" line go away.
- After fm-9mm.12 ships, the source name in a row links to `/sessions/:id`.

## Interfaces
- Consumes `?card=<id>` from the triage list ticket.

## Design pack
Flows F3.

## Acceptance
- [ ] The drawer has no `decision-*` form; Open lands on `/needs-you?card=<id>` with that card open (spec acceptance 11).
- [ ] verify ui of the drawer with 0, 1 and 7 cards at 1440 and 820, light and dark.
