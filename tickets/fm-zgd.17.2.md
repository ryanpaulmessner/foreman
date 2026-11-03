---
id: fm-zgd.17.2
title: "Question cards: compact open card with the Asked by row and one footer"
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
Spec Decisions 12-20 and 23 (option A's layout, used as C's open card). Today's cards all stay open in this ticket.
- Compact layout inside one border (Decision 12): one header line, the source row, What and Why now as a short definition list parsed from the card text (Decision 13: same label match as the ask lint); Part of, From and agent notes fold under "More context". The board's own context block and the kind words "Internal" and "Unsorted" go away.
- Asked by row, "Live or ended" (Ryan, card 86cedfd3; Decisions 14-15): live, ended with "answer goes to <coordinator>", ended with "your answer resumes it", unknown. Focus icon (off with "The pane is closed" when ended). "Go to session" goes away.
  Fallback until fm-9mm.9/fm-9mm.12 ship (Decision 14): name as plain text, role as the harness word, live or ended from today's lookup, "answer goes to" and "Find the session" hidden. Build it through one source-view function; fm-9mm.12 fills it from `agent_sessions` and adds the link, without a second row.
- Body by kind (Decision 16).
- Footer strip (Ryan, card ae840da9; Decision 17): Decline is a button next to Answer; Ask about this, Wrong question and Withdraw are small text actions at the right end, Wrong question and Withdraw last; each opens its panel with the Decision 18 copy.
- Footer panel machine `Foreman.CardFooterPanel` (Decision 40): states none, ask, wrong_question, withdraw; rules P1 at most one panel open, P2 opening scrolls the card to the top; panel text kept on card_closed. Generated docs page.
- Focus failure lines and session waiting notices in the info style (Decisions 19-20).

## Interfaces
- Consumes the status line and copy field (shared fixes ticket).
- Shares the source-view function with fm-9mm.12.
- Produces the open card component the triage list ticket renders.

## Design pack
State "Proposed: footer panel"; Flows F4; UI "States per changed screen".

## Acceptance
- [ ] No card at load shows a tmux command, "Go to session", "Source unknown ·" or "This session has ended."; an ended source shows its end time and the Focus icon off (spec acceptance 3).
- [ ] Findings A1-A4, (c)8, (c)9 fixed (spec acceptance 2).
- [ ] Machine tests for P1, P2 and kept panel text.
- [ ] A card whose text has no What and no Why now shows today's text with "Show more".
- [ ] The open decision card is at most 540 px tall at 1440.
- [ ] verify ui of each kind and each source row variant at 1440 and 820, light and dark.
