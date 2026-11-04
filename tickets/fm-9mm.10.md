---
id: fm-9mm.10
title: "Session lifecycle machine and the shared state function"
type: task
status: closed
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.9"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-04
close_reason: "Merged in PR #10 (7bf6f11); deployed 2026-11-04 (migration 20261104152616; live states after 3 min: working 7, idle 12, parked 2, ended 102)"
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 7-9.
- A declared `Foreman.Fsm` machine on `agent_sessions.state` for every kind (kind as a guard), with exactly the Decision 7 table: starting, working, idle, waiting.question / .permission / .usage_limit, parked, ended; claimed events outside the table are refused, observed ones ignored. Every `Foreman.SessionMachine` transition that changes liveness fires the matching event in the same transaction.
- Observers that fire output_changed, quiet (2 min), asked, last_card_closed, permission_prompt, usage_limit, pane_gone/exited from the existing monitor and hooks, at most one tmux call per monitor tick, no `capture-pane`.
- One pure state function: (state, open cards, ticket stage, ended time) -> label, colour, second line (Decision 9 table and second lines; times in the shared human format). No other session colour map.
- A `:sessions_changed` broadcast on each tick that changes a row.
- Generated machine docs page.

## Interfaces
- Consumes `agent_sessions` (identity ticket).
- Produces: the machine's events (used by controls tickets), the state function (used by every page), the `:sessions_changed` broadcast (Tree, Grid).

## Rules to keep (Decision 8)
R1 one label at all times; R2 an open card means "waiting on you" even after end; R3 dead sessions offer no Focus, Send message, Continue, Park, Stop; R4 Resume only when resumable; R5 Stop keeps worktree and branch; R6 main coordinator never parks; R7 one live session per name; R8 builds outlive their coordinator; R9 open card on an ended session; R10 every dead build has Resume, Relaunch build or is closed out; R11 Park and Stop close only the session's pane.

## Design pack
State part: "Proposed", "Check (statechart, 2026-11-02)", "Proposed: coordinator session".

## Acceptance
- [ ] A machine test for every row of the Decision 7 table, and one per rule R1-R11 that the machine owns.
- [ ] Table test for the state function: one case per label row and second line.
- [ ] Code search finds no other session state-colour map (spec acceptance 15).
- [ ] A quiet pane goes working -> idle after 2 min with no `capture-pane` call (tmux command log on a scratch socket).
- [ ] `mix foreman.fsm.docs` output includes the new machine.
