---
id: fm-fdw
title: "Waiting without a card: split by who acts, a working button per row, design pass"
type: feature
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["ux"]
created: 2026-11-02
closed: null
close_reason: null
---

Ryan 2026-11-02: the 'Waiting on you without a card' section on Needs you does not work and has no design.

## Problem
- Each item is a link that only opens the ticket panel. 'Request a push' and 'Review the report' have no matching action there; the only button in the panel is the preview Start, so it looks like the buttons do nothing.
- 14 of 18 live items are agent close-out work (reports to review, push cards to post), not Ryan's. 4 are PRs he merges on GitHub.
- No design pass: tall bordered boxes, no grouping, counts, age or owner.

## Direction (mockup first, approved before build)
- Two groups: 'Yours' (PRs to merge, decisions with no card) and 'Stalled agent work' (collapsed by default) with the owner coordinator.
- One-line rows: repo · ticket · title · age · owner, and a button that does the action: Open PR on GitHub, Nudge owner (sends a coordinator note), Dismiss until it changes.
- Checked at 1440x900, 820x1180, 390x844, light and dark.

## Acceptance
- [ ] Mockup approved by Ryan.
- [ ] No row links to a place without its action.
- [ ] Nudge reaches the owning coordinator or says why it cannot.
- [ ] Dismiss hides the row until the item's state changes.
- [ ] Screenshots at three widths, both themes, on the push card.
