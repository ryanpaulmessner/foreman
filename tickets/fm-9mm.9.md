---
id: fm-9mm.9
title: "Session identity: one agent_sessions row per session, and asks that resolve to it"
type: task
status: closed
priority: 2
parent: fm-9mm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-04
close_reason: "Merged in PR #8 (8bc167c); deployed 2026-11-04 (agent_sessions 98 rows; CLI rebuilt); full suite failures equal base"
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 1-6 (step 1 of the build order).
- New `agent_sessions` table (fields in Decision 1) with a partial unique index on `name` where `ended_at` is null (Decision 2). `planning_sessions`, dispatch `sessions` and `approval_requests` get `agent_session_id`.
- Migration fills rows from the 14 registrations, the 3 planning rows and dispatch rows that have a pane id and their own name. Requests are not backfilled.
- Writers: board launch writes the row in the same transaction as `planning_sessions`; `foreman session register` takes `$TMUX_PANE` and `--parent`; `foreman dispatch` takes `--name` and `--pi-session` and resolves the parent from the caller's `FOREMAN_SESSION`. Board-launched planning sessions are `epic_coordinator` rows under the main coordinator (Decision 4).
- `foreman ask` always sends `FOREMAN_SESSION` and `$TMUX_PANE`; the server resolves by live name, then live pane, stores `agent_session_id` when it accepts the request, and prints the unknown-session warning (exact text in Decision 5) when nothing matches.
- The card source lookup and coordinator notes read `agent_sessions` instead of matching names.

## Interfaces
- Produces: the `agent_sessions` schema and a sessions-context lookup (by id, by live name, by live pane); `agent_session_id` on requests. Consumed by every later ticket.
- Produces CLI flags `dispatch --name --pi-session`, `session register --parent`, used by the launch-scripts ticket.

## Design pack
Data part, "Proposed" ER diagram and "Decisions (Ryan, 2026-11-02, fm-9mm.1)"; Flows "ask identity resolution".

## Acceptance
- [ ] Migration on a copy of the schema creates the table, the index and the backfill counts above (test).
- [ ] Two live rows with one name are refused; a name is reusable after `ended_at` is set (test).
- [ ] `foreman ask` from a registered pane stores the right `agent_session_id`; a build never resolves to its coordinator's row (context test, spec acceptance 1-2 shape).
- [ ] `foreman ask` from an unregistered shell is accepted, prints the Decision 5 warning, and the card shows the unknown source with no tmux command (spec acceptance 3).
- [ ] CLI tests for `ask`, `dispatch --name --pi-session`, `session register --parent`.
- [ ] Coordinator notes still reach the right pane, now looked up by row.
- [ ] `mix precommit` failures equal the base's.
