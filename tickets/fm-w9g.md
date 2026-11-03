---
id: fm-w9g
title: "Record the dispatching coordinator on every build, and give old stuck items an owner"
type: task
status: closed
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-03
close_reason: "Folded into fm-9mm.11 (launch scripts record identity, incl. --coordinator and the 14 ownerless items)."
---

Follow-up from fm-fdw (PR #6).

- `pi-window` (skills repo, dispatch scripts) passes `--coordinator <own session>` to `foreman dispatch`, so close-out notes reach the right coordinator. Today the owner is found from the dispatching pane only.
- Document `--coordinator` in the foreman skill (Ticket stages table).
- The 14 items that were stuck when fm-fdw shipped were dispatched before `--coordinator` existed, so they are recorded as ownerless and get no note. Decide: close them out by hand, or set their owner once.

Acceptance: a new pane build dispatched by an epic coordinator records that coordinator; `close_out_nags` has no ownerless row for builds dispatched after the change.
