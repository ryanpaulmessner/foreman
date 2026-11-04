---
id: fm-3fm
title: "Initiative plan: rank initiatives, order their stacks, and nudge the top ones forward"
type: epic
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:map"]
created: 2026-11-04
closed: null
close_reason: null
---

## Destination

An approved spec, with its design pack, for an **initiative plan** on the board: Ryan keeps a standing ranked list of initiatives (epics, across repos), sets how many of the top ones move forward (N), and drags the ticket order inside each initiative. When an initiative in the top N has a next piece ready, the board nudges its coordinator (or the main coordinator when it has none) to start it. Ready for `to-tickets`.

## Notes

- Ryan's answers while charting (2026-11-04, chat):
  - Auto forward = the board **nudges the coordinator**; the coordinator dispatches as today. The board does not launch builds itself, and pushes and merges still go through cards.
  - The plan is a **standing order**: set once, kept until changed. "Today" is whatever is at the top now.
  - No live coordinator: the nudge goes to the **main coordinator**.
  - Order inside an initiative: **drag to order**, stored on the board (Postgres), like the priority overrides.
  - Limit: only the **top N** initiatives get nudged; Ryan sets N.
  - Business priority: **Ryan ranks by hand**; an optional link per initiative to its Asana task or Support Board T-### shows the reason.
- Builds on: ticket priority and Jump to front (fm-c2w.23, done), orient/dispatch honouring board priority (fm-c2w.27, open), coordinator notes and close-out nags (fm-fdw), session identity and the lifecycle machine (fm-9mm.9, fm-9mm.10), Launch coordinator (fm-9mm.18).
- House rules: board state is Postgres only and the app never writes ticket files; stateful features sit on declared `Foreman.Fsm` machines; on-screen copy follows ASD-STE100 with no how-it-works text.
- Skills: `grilling` and `domain-modeling` for every grilling ticket; `design-pack` for data and state prototypes; `statechart` for the nudge rules; real board CSS and `ux-critique` for screen prototypes; `ui-patterns` for states.
- When Ryan is not in the chat, HITL questions go to him as board cards, one question per card.

## Decisions so far

- [How do coordinators pick their next ticket today, and where would a board nudge land?](tickets/fm-3fm.1.md): by hand (orient recommends, dispatch waits for a yes) and blind to board priority; build a new start-nudge machine on the close-out nag pattern; fm-c2w.27's skill and ready parts fold in here. Research: branch research/plan-nudge, docs/research/plan-nudge.md.
- [How do initiative rank, stack order, ticket priority and Jump to front combine into one 'next up' per initiative?](tickets/fm-3fm.2.md): initiative = top-level epic, one ranked list across repos; next up = pending jump, then your drag order (beats P0-P4), then priority and age; a jump moves the ticket to the top of its stack only.

## Not yet specified

- The orient, dispatch and foreman ready changes that make coordinators read the plan (folded in from fm-c2w.27); sharp once the nudge statechart is chosen.
- How the plan shows on other pages: Initiatives ordering, Needs you, This week and the Friday report.
- What Ryan sees to judge that the plan works (for example "top initiative idle for 2 h" as a signal), and whether that is a page, a badge or nothing.
- Work repo (ReportSystem, human merge) initiatives next to foreman and skills initiatives in one list: any rule that differs by repo.

## Out of scope

- The board dispatching builds on its own (Ryan chose nudges, 2026-11-04).
- Reading priorities or due dates from Asana.
- A new plan each day that expires.
