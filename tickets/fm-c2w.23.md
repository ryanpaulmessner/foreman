---
id: fm-c2w.23
title: "Ticket priority on the board: see it, change it, and jump an item to the front of the queue"
type: feature
status: closed
priority: 1
parent: fm-c2w
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: 2026-10-20
close_reason: "5c5b6a1 on main; migration 20261020201243 applied to foreman_dev before merge; review clean"
---

User 2026-10-19: 'we should also be able to assign priority to tickets, so if a high priority item comes through we can jump it to the front of the queue.' Ticket files already have priority (0-4; foreman new --priority works) but nothing on the board uses it.

- Show priority on every ticket row, card and the ticket detail (P0..P4, P0/P1 visually distinct).
- Change it from the board (ticket detail control) and the CLI (foreman update <id> --priority N; check it exists and validates).
- Ordering: ready frontier (foreman ready, Initiatives lists, dispatch's ready-repos) sorts by priority, then age. Needs you sorts by the ticket's priority, then oldest first.
- 'Jump to front': one button that sets P0 and notifies the coordinator (a board event the coordinator's orient/dispatch reads first; Needs you does not need a card).
- Board writes ticket files? House rule says the app never writes ticket files: decide the path (CLI write from a board action through the agent API, or a board-side priority override in Postgres that wins over the file). Spec the choice; ask the user via a decision card.
Acceptance: tests for ordering and the override; screenshots; mix precommit only base env failures.
