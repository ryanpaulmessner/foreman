---
id: fm-zgd.17.2
title: "Question cards: compact open card with the Asked by row and one footer"
type: task
status: closed
priority: 2
parent: fm-zgd.17
blocked_by: ["fm-zgd.17.1"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-04
close_reason: "Merged in PR #12 (cf22e01); live on Needs you 2026-11-04; screenshots approved on card 745f3d72 after round 2 (one text box, no Always)"
---

Spec: `docs/specs/question-cards.md` (approved 2026-11-03, card 63a4319f). Design pack: `docs/specs/question-cards.design.md`. Mockup: https://claude.ai/artifact/KkSwALbmBHC1TZg1vJf3jW (option C). The spec's Non-goals, Ask-first boundaries and copy apply to every ticket. Desktop only: 1440 and 820, light and dark.

## What to build
Spec Decisions 12-20 and 23 (option A's layout, used as C's open card). Today's cards all stay open in this ticket.
- Compact layout inside one border (Decision 12): one header line, the source row, What and Why now as a short definition list parsed from the card text (Decision 13: same label match as the ask lint); Part of, From and agent notes fold under "More context". The board's own context block and the kind words "Internal" and "Unsorted" go away.
- Asked by row, "Live or ended" (Ryan, card 86cedfd3; Decisions 14-15): live, ended with "answer goes to <coordinator>", ended with "your answer resumes it", unknown. Focus icon (off with "The pane is closed" when ended). "Go to session" goes away.
  Fallback until fm-9mm.9/fm-9mm.12 ship (Decision 14): name as plain text, role as the harness word, live or ended from today's lookup, "answer goes to" and "Find the session" hidden. Build it through one source-view function; fm-9mm.12 fills it from `agent_sessions` and adds the link, without a second row.
- Body by kind (Decision 16).
- Footer (Ryan, card ae840da9; amended 2026-11-04, cards 602ad7c1 and 8ff81918; Decision 17): one text box; the primary button and Decline send it as the note, Ask sends it to the session (Decision 18), Wrong question and Withdraw use it as the reason and are off until there is text. No panels. No "Always use this answer" on cards.
- Ask state machine `Foreman.CardAsk` (Decision 40 as amended): idle, copy, failed; text kept on card_closed. Generated docs page.
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
- [ ] Machine tests for Foreman.CardAsk and kept text; Ask, Wrong question and Withdraw off until there is text; no Always on cards.
- [ ] A card whose text has no What and no Why now shows today's text with "Show more".
- [ ] The open decision card is at most 540 px tall at 1440.
- [ ] verify ui of each kind and each source row variant at 1440 and 820, light and dark.

## Notes
- 2026-11-04 claude: 2026-11-04 Ryan (review 725595c6 'Change it'; cards 602ad7c1, 8ff81918): one text box per card; the button decides what the text is for: Answer sends it as the note, a second button Ask sends it to the agent as a question and keeps the card open, Wrong question and Withdraw stay as small actions that use the same text as their reason (off until there is text), no panels. Remove 'Always use this answer' from cards; existing standing answers keep working and stay visible on the Answers page (fm-zgd.17.5).
