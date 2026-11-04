---
id: fm-3fm.2
title: "How do initiative rank, stack order, ticket priority and Jump to front combine into one 'next up' per initiative?"
type: decision
status: closed
priority: 2
parent: fm-3fm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:prototype"]
created: 2026-11-04
closed: 2026-11-04
close_reason: "top-level epics ranked across repos; next up = jump, then drag order, then priority and age; jump moves a ticket to drag position 1 only"
---

## Question

Draw the data and the ordering rule (design-pack rules: "Now" from code, "Proposed" with changes marked): where the standing initiative rank, N, and the per-initiative drag order are stored (Postgres, next to the priority overrides); how a drag order relates to P0-P4 and to Jump to front (which wins, and what a jump does to a dragged order); what happens to the order when tickets are added, closed or re-parented in the ticket files; initiatives in different repos in one list. Ryan reacts to the diagram and a worked example of five tickets.

## Notes
- 2026-11-04 user: Answer (prototype, Ryan 2026-11-04 in chat): Data: new plan_settings (one row: top_n), plan_initiatives (repo_key, epic_id, rank unique across repos, reason_url), stack_positions (repo_key, bead_id, epic_id, position; only tickets Ryan dragged); priority_overrides and the jump stage event unchanged. Initiative = a top-level epic (no parent epic); its stack is every ticket under it at any depth. Next up = first of open, unblocked, non-epic, queued tickets under the epic, ordered: (1) a pending Jump to front, which also moves the ticket to drag position 1 of its initiative and does not move the initiative in the ranked list; (2) dragged tickets in drag order (drag beats P0-P4); (3) the rest by priority, then oldest. Closed tickets drop out, new ones join group 3, a re-parented ticket loses its position (positions are per epic). Worked example: fm-9mm stack (.18 dragged 1, .12 dragged 2, new .21 P1 undragged 3rd, blocked .13 and P0 .17 not candidates).
