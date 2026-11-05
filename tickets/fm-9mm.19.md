---
id: fm-9mm.19
title: "Sessions page: Grid view and the Tree · Grid switch"
type: task
status: in_progress
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.13","fm-9mm.17"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: null
close_reason: null
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 32-34 (step 5, option D).
- `Tree · Grid` switch next to the strip; Tree first; choice remembered per viewer in `localStorage`.
- Grid: cards grouped by coordinator in a sunken region, coordinator card first, builds in order waiting, working, in review, idle, ended; 4 columns at 1440, 2 at 820. Card content per Decision 33; dead pane shows "The terminal is closed".
- Reads: only visible cards (observer hook tells the server), 3 s for working and waiting, 30 s for idle, never dead, nothing while hidden; one tmux call per check for all visible panes; push on hash change; Claude panes drop input box and status lines before the last 6.
- Settle the left-open details from the spec's starting point: Working cards on base border with 2 px info top edge; ended as one-line chips at group end; strip above the grid below 1100 px.
- Grid states: success, empty and errors as Tree; loading skeleton of 3 groups.

## Interfaces
- Consumes the pane reader machine and the Tree page.

## Acceptance
- [ ] With 11 visible live cards, at most one tmux process per 3 s (tmux command log); a hidden tab stops all reads (spec acceptance 13).
- [ ] LiveView tests for the switch and each grid state.
- [ ] verify ui at 1440 and 820, light and dark.
