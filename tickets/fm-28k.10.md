---
id: fm-28k.10
title: "Dispatch sessions never end, so cards point at closed windows"
type: bug
status: in_progress
priority: 2
parent: fm-28k
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: null
close_reason: null
---

About 35 dispatch rows have ended_at empty although their panes are gone; 23 cards hit 'window closed'.
## Acceptance
- [ ] A periodic check ends sessions whose tmux pane no longer exists; Go to session hides or explains ended sessions.
- [ ] Test with a fake tmux listing.
