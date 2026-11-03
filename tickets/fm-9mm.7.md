---
id: fm-9mm.7
title: "Session detail page: live view, dead view and controls"
type: decision
status: closed
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.3","fm-9mm.4","fm-9mm.5"]
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:prototype"]
created: 2026-11-01
closed: 2026-11-03
close_reason: "Ryan picked B with A's round grouping (card f438c994, 2026-11-03)"
---

## Question

Design /sessions/:id: identity header, state, timeline (stage events, progress notes, reports, cards), recent pane output, and the controls from the map Notes, each with when it is enabled, its confirm and its result message. Design the dead view (ended at …, history, Resume or Relaunch) and how a card's source link and focus icon lead here. Variants from the board's real CSS, published as an Artifact, `ux-critique` before Ryan reacts; record the chosen variant and its states (`ui-patterns`).

## Notes
- 2026-11-03 user: 2026-11-03 Ryan picked B + A's round grouping (card f438c994). B: one column at the Needs-you width, ticket title as heading with the session name under it, next-step panel with one filled button, only the controls that work now plus one line of off reasons, tabs Recent output / Timeline / Details; timeline grouped by review round with old rounds folded (from A). Ryan's note: 'watch the buttons on the sidebar, the text is overflowing on the mockup' - in A's controls rail (sd-A-deadcard-1440.png) 'Answer on the card' runs past its fixed-width button. Build rule: buttons size to their label (no fixed widths), labels never wrap or overflow; check every control label at 820 and 1440 in verify ui. Still open on other cards: Continue before a usage limit resets (4e77750e); card source row live/ended vs state badge (to ask).
- 2026-11-03 user: 2026-11-03 Ryan answered card 4e77750e (Continue before a usage limit resets): 'Keep it on' - Continue always works; the page shows the reset time. Ryan's note: 'have a way to fallback to other models'. Spec must add a usage-limit control to continue on another model (for Pi builds: relaunch/resume with another --model, e.g. openai-codex/gpt-6-astra <-> anthropic/claude-opus-5-5; for Claude coordinators: what a fallback means is not yet known - check before specifying).
