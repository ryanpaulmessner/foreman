---
id: fm-9mm.11
title: "Launch scripts record session identity (pi-window, coord, relay)"
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
close_reason: "Skills PR #1 (sk-rby, baec776) and foreman PR #11 (603b295) merged; skills main pulled; relay patch applied by Ryan (chore 998d01ff); fm-w9g owner note for filter-design pending"
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decision 3 writers that live outside this repo (skills repo dispatch scripts, `coord`, the relay), and fm-w9g.
- `pi-window` (window and pane mode) generates a Pi session uuid, starts Pi with `pi --session-id <uuid>`, and calls `foreman dispatch --name <build> --pi-session <uuid> --coordinator <own FOREMAN_SESSION>`.
- `coord` and `foreman coordinator` launched outside the board call `foreman session register` with `$TMUX_PANE`.
- The relay `open` step calls `foreman session register --parent <coordinator>`.
- Document the new flags in the foreman and dispatch skills.
- fm-w9g: decide with Ryan (one card) how the 14 items stuck before fm-fdw get an owner, and do it.

## Interfaces
- Consumes CLI flags from the identity ticket.

## Acceptance
- [ ] A pane build launched by an epic coordinator in pane mode gets its own row: name = its `--name`, parent = the coordinator's row, `pane_id` = its `%N`, `conversation_id` = the Pi session id (spec acceptance 2), shown on a scratch tmux server.
- [ ] A `coord` launch creates a registered row whose name equals its window name.
- [ ] `close_out_nags` has no ownerless row for builds dispatched after this change.
- [ ] Skill docs updated; skills repo changes go through its own push card.

## Notes
- 2026-11-04 user: fm-w9g: card 0e60a01f answered 2026-11-04 by Ryan: 'have the filter-design coordinator handle them'. 3 items still ownerless (work-n7p.8, work-n7p.11, work-n7p.16; push close-out) go to filter-design (pane %395) as one note; no owner-lookup change. Not yet sent: the pane had unsent text from Ryan at 16:16 UTC.
