---
id: fm-9mm.12
title: "Session page /sessions/:id: live and dead views, and every source link"
type: task
status: closed
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.10"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-04
close_reason: "Merged in PR #13 (8ecaaaf); live 2026-11-04 (/sessions/<foreman-board> renders); screenshots approved on card aa86367e"
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 10-13, 16, 21, 22 (step 2), read-only part.
- `/sessions/:id` in `Layouts.app` (`active={:sessions}`), option B with A's round grouping: breadcrumb, heading, badge and second line from the state function, next-step panel, the "Not available now:" line, tabs Recent output (placeholder until the output ticket), Timeline, Details.
- Timeline grouped by review round (Decision 13); default tab (Decision 12).
- Details tab with the one shared copy field for the attach command (Decision 16).
- Unknown id: breadcrumb and "The board has no session with this id." Never an error box.
- Card source row (Decision 21, all variants and the Focus icon) replacing "Source" and "Go to session" on today's card. Build it through the one source-view function the question cards ticket uses, and fill it from `agent_sessions`; do not add a second row.
- Every source link goes to `/sessions/:id` (Decision 22): card name, request drawer, ticket panel Sessions tab (rows: badge, name link, role, last seen; empty "No sessions for this ticket."), epic page session line. Initiatives strip keeps badge, name link, Focus; Relaunch and Start fresh leave it (Ryan, card 06a13e91).
- Every state and its copy from the spec's "Session detail page" copy table that does not need output or controls.

## Interfaces
- Consumes the state function and `agent_sessions`.
- Shares the source-view function with question cards ticket "Compact open card" (whichever lands second adapts to it).
- Produces the page shell the output and controls tickets fill.

## Design pack
UI part, "Changed screens and their states"; Flows "opening a session from a card (live and dead)"; mockup https://claude.ai/artifact/3tu2g2ucMsvuV3UdcpcWMG (option B).

## Acceptance
- [ ] Every source link on a card, the drawer, the ticket Sessions tab and the epic page navigates to `/sessions/:id`; a closed pane shows the dead view, never an error (spec acceptance 4).
- [ ] LiveView tests with element ids for each panel state in the copy table this ticket owns, the unknown id, and each source row variant.
- [ ] No card shows a tmux command at load.
- [ ] verify ui at 1440 and 820, light and dark, before and after, screenshots looked at.
