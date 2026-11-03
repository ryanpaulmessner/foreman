---
id: fm-zgd.17.1
title: "Question cards: shared fixes on today's cards"
type: task
status: closed
priority: 2
parent: fm-zgd.17
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-03
close_reason: "Merged in PR #7 (bf1f44a); screenshots approved on card 70722dfb; touched suites 195 tests 0 failures"
---

Spec: `docs/specs/question-cards.md` (approved 2026-11-03, card 63a4319f). Design pack: `docs/specs/question-cards.design.md`. Mockup: https://claude.ai/artifact/KkSwALbmBHC1TZg1vJf3jW (option C). The spec's Non-goals, Ask-first boundaries and copy apply to every ticket. Desktop only: 1440 and 820, light and dark.

## What to build
Spec Decisions 21-26 and 28, on today's cards and pages, before the layout changes.
- Three status line styles (success, error with Try again when a retry can work, info), each with an icon; the board flash group uses the same styles.
- One copy pattern: read-only mono field and Copy button; "Copied" with a check for 2 s; selects the text if the clipboard fails (client hook). Every copy box on the changed screens uses it.
- "Always use this answer" label with an 8 px gap.
- Long ids and paths: `overflow-wrap: anywhere` with a break opportunity after each "/"; no `break-all` on the changed screens.
- Ticket and document panel under 1024 px: right sheet `min(460px, 100% - 96px)` over a scrim; Esc, X and scrim close it; one copy of the panel at any width.
- No actor word ("user", "claude", "pi") as a label on the changed screens.
- Board parts only: no new hex colours; new `bb-` classes next to `.bb-panel`.

## Interfaces
- Produces the status line component and the copy field hook, used by every later question cards ticket and by the Sessions page Details tab (fm-9mm.12).

## Acceptance
- [ ] Copy changes to "Copied" for 2 s; clipboard failure selects the text (spec acceptance 10).
- [ ] A push card with a long worktree path at 820 breaks only after "/" or where there is no other place (spec acceptance 2, (c)12).
- [ ] At 820 the ticket panel opens as a right sheet; sidebar and list edge stay visible; Esc closes it (spec acceptance 13).
- [ ] Info and error flashes look different; colour is never the only cue.
- [ ] verify ui before and after at 1440 and 820, light and dark.
