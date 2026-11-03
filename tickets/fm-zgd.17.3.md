---
id: fm-zgd.17.3
title: "Question cards: triage list on Needs you, one card open, next opens"
type: task
status: open
priority: 2
parent: fm-zgd.17
blocked_by: ["fm-zgd.17.2"]
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
Spec Decisions 1-11, 29-32 and 39 (Ryan, card 3baa2f59: option C).
- Card list machine `Foreman.CardList` (Decision 39): which card is open; result and info lines are its effects. Generated docs page.
- Every pending card not open is one row: kind badge, question (one line, ellipsis, full text in tooltip), source text (Decision 2), age in the shared format; at 820 the source moves under the question.
- One card open at a time (Decision 3): row click, Enter or Space opens it and closes the other; 3 px accent bar; Close card leaves all rows.
- After you act, the result line (Decision 30 copy) takes the card's place for 10 s and the next card opens (Decisions 4-5). List order stays today's, per-ticket headings go (Decision 6).
- `?card=<id>` in the URL (Decision 7), with the load and stale-link rules.
- Input kept per card on the server (Decision 8); a poll never resets the open form.
- New cards join as rows and never move the open card; an empty list opens the new card (Decision 9).
- Closed elsewhere: info line, typed note shown in a copy field, next opens (Decision 10).
- All Needs you page states and the info and error line copy (Decisions 29, 31, 32).

## Interfaces
- Consumes the open card component; produces `?card=<id>` used by the drawer ticket.

## Rules to keep (card list machine, pack "Proposed: card list")
At most one open card; a poll or a new card never closes, moves or resets the open card; your input survives closing and reopening; next is the row under the resolved card, else the first.

## Design pack
State "Proposed: card list"; Flows F1, F2.

## Acceptance
- [ ] With 7 pending cards all 7 show in the first view at 1440x900 and 820x1180 (baseline: 0 full cards; spec acceptance 1).
- [ ] Exactly one `card-open-*` element with 3 cards; clicking a row makes it the only open one (spec acceptance 4).
- [ ] Answer: `card-result-<id>` with Decision 30 copy, the next row opens, after 10 s the line is gone and the card is in Recent outcomes (spec acceptance 5).
- [ ] Input kept across switching and a poll (spec acceptance 6); poll does not move the open card (7); closed elsewhere from a second tab (8); failure keeps input and Try again resends (9).
- [ ] `mix foreman.fsm.docs` includes the new machines (spec acceptance 14).
- [ ] Ryan answers a real card in his browser and sees the result line and the next card open (spec acceptance 15).
- [ ] verify ui of every Needs you state at 1440 and 820, light and dark.
