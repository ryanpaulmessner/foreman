---
id: fm-c2w.25
title: "Unplanned list: show each ticket's age and sort newest first"
type: feature
status: open
priority: 2
parent: fm-c2w
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-20
closed: null
close_reason: null
---

Ryan 2026-10-20: in Initiatives → Unplanned it is hard to tell what was just added and what has been sitting for weeks. Show the ticket's created date as a short age ("today", "3d", "5w") with the full date on hover, on every ticket row (Unplanned and epic children), and sort Unplanned tickets newest first inside each project. Optional: a subtle warning tint when an open ticket is older than 30 days. Data: the ticket's created date is in beads.raw (files tracker: created; beads: created_at). Acceptance: rows show age; Unplanned sorts newest first; LiveView test for both; no extra query per row.
