---
id: fm-3fm.2
title: "How do initiative rank, stack order, ticket priority and Jump to front combine into one 'next up' per initiative?"
type: decision
status: open
priority: 2
parent: fm-3fm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:prototype"]
created: 2026-11-04
closed: null
close_reason: null
---

## Question

Draw the data and the ordering rule (design-pack rules: "Now" from code, "Proposed" with changes marked): where the standing initiative rank, N, and the per-initiative drag order are stored (Postgres, next to the priority overrides); how a drag order relates to P0-P4 and to Jump to front (which wins, and what a jump does to a dragged order); what happens to the order when tickets are added, closed or re-parented in the ticket files; initiatives in different repos in one list. Ryan reacts to the diagram and a worked example of five tickets.
