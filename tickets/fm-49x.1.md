---
id: fm-49x.1
title: "This week page: worked tickets by kind and plain stage"
type: feature
status: open
priority: 2
parent: fm-49x
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: null
close_reason: null
---

## What to build
The `/week` page ("This week" in the left menu, under Initiatives) lists every work-repo ticket worked in the current workweek, by kind and plain stage. Spec: epic body, decisions 1–4, 7, 8, 13 (basic details).
- Board config `board.timezone` (default `America/Chicago`) and a time zone database dependency; `board.week_repos` (default `["work"]`).
- Week window: Monday 00:00 to Sunday 23:59 in the board time zone. File dates count for the whole day.
- Activity: `stage_events`, `approval_requests` / `request_events`, ticket-file dates (`## Notes` line dates, `closed`, `parked`).
- Sections by effective kind: Feature (sub-heading per epic), Break-fix, Mapping, Access, Internal, Unsorted. Empty sections do not render.
- Plain stages in this ticket: Done, Closed, not done, Waiting on you, Waiting on others, Building, Not started (decision 8 table, first match wins). Shipped and On staging come in the PR ticket; until then an item with a merged PR shows Waiting on others or Building per the table.
- Expanded item: board stage, request id if any, kind, epic, last activity date, ticket file link.

## Interfaces
Produces the pure page-model module: input = tickets, events, requests, PR containment results (empty here), sent reports (empty here), "now" in the board time zone; output = sections → stage groups → items. Tickets 2–6 extend it; keep it table-driven.

## Acceptance
- [ ] Acceptance check 1: list for the week of 2026-10-20 equals a SQL count of distinct tickets from `stage_events` and `approval_requests` in the week plus a grep of ticket-file dates; nothing outside the week shows.
- [ ] Acceptance check 7: a `stage_events` row at Monday 03:00 UTC counts in the previous week.
- [ ] One table-driven test per plain-stage row in this ticket, including the close-reason prefixes for Closed, not done and board stage `abandoned`.
- [ ] LiveView test: sections render in order, empty sections hidden, an item expands.
- [ ] Light and dark desktop screenshots of `/week`.
- [ ] `mix precommit` as the base, except new tests.
