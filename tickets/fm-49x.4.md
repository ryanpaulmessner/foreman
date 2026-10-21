---
id: fm-49x.4
title: "Carried over section and week navigation"
type: feature
status: open
priority: 2
parent: fm-49x
blocked_by: ["fm-49x.1"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: null
close_reason: null
---

## What to build
Carried over and week navigation. Spec decisions 5, 6 (without the report seed), 15b (arrows only).
- Carried over section above the kind sections, same inner grouping: tickets with activity in the previous week that are not Shipped, Done or Closed, not done, plus tickets Shipped or Done now that are in no sent report (until the report ticket lands, no report counts as sent).
- "carried N weeks": N = consecutive earlier weeks with activity for the ticket, from today's state only. Activity before 2026-10-18 comes from ticket-file dates only.
- Back and forward arrows; the URL holds the week so a reload keeps it.

## Interfaces
Extends the page model with a carried-over section and a `carried_weeks` count per item; takes the week start as input.

## Acceptance
- [ ] Acceptance check 3 (first half): a ticket active in the week of 10/13 and not done shows under Carried over with "carried 1 week".
- [ ] Table tests: N = 0, 1, 2 with a gap week; a Closed, not done item shows only in the week it closed.
- [ ] LiveView test: arrows change the week; reload keeps it.
