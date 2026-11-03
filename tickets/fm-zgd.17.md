---
id: fm-zgd.17
title: "Question cards and Answers page: design pass"
type: feature
status: open
priority: 2
parent: fm-zgd
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["design"]
created: 2026-11-03
closed: null
close_reason: null
---

Ryan, 2026-11-03: "the questions UI is looking kinda rough". The decision and question cards on Needs you never had their own design pass. Each fix added a piece (What / Part of / From / Why now context, the Reply box, Ask about this, Wrong question, Always), so the card is now about 800 px tall and its parts do not read as one card.

## What to do
Make 2-3 options for the decision/question card and the Answers page. Build them from the board's real compiled CSS and rendered markup, with real cards from foreman_dev, at 1440 and 820 in light and dark. Publish them as an Artifact. Run ux-critique and ux-laws on them before Ryan picks. Record the chosen option with its empty, loading, error and success states (ui-patterns). Then spec, tickets and Pi builds.

## Findings to fix (from the board audit, docs/specs/sessions-view-audit/ux-audit.md, fm-9mm.4)
- A2: the card names the asking session three times, two of them in opposite order. Use one source row: state badge plus a name link. The session detail mockup (fm-9mm.7, card source row option) already shows a before and after for this. Reuse it.
- A1, A3, A4: Go to session fails only after the click. Source unknown puts a raw tmux command on the card. 'This session has ended.' gives no time and no next step.
- A5: five different copy-command patterns, and none of them says Copied.
- A9: one card fills the screen at 1440. Pick a density that shows 2-3 cards in the first view.
- A10: at 820 the side panel covers the whole page.
- (c)1: Answers page: the Search, Repo and Ticket inputs cannot be seen (no border or fill), no gap after Show archived, and the column is centred while other pages are left-aligned.
- (c)2: info and error flashes look the same.
- (c)3: no gap between the Always checkbox and its label.
- (c)8: kind words Internal and Unsorted tell the user nothing.
- (c)9: Wrong question and Ask about this sit outside the card border.
- (c)10: the request drawer repeats the full cards.
- (c)12: long ids and paths break in the middle at 820.

## Stay consistent with
The same audit, section (b): Layouts.app and bb-nav, board tokens, one shared state-colour function, and the empty, loading and error style. The question card must match the Sessions pages (fm-9mm.6, .7) and the Waiting without a card section (fm-fdw).

## Acceptance
- [ ] Ryan picks an option on a board card after the critique.
- [ ] Every finding above is fixed or listed with a reason it is out.
- [ ] verify ui screenshots of Needs you and Answers at 1440 and 820, light and dark, before and after, on the push card.
