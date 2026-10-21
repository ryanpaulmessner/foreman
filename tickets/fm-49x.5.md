---
id: fm-49x.5
title: "Weekly report: draft, edit, save, mark as sent"
type: feature
status: open
priority: 2
parent: fm-49x
blocked_by: ["fm-49x.2","fm-49x.3","fm-49x.4"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: null
close_reason: null
---

## What to build
The weekly report for Arnoldo, from the page. Spec decisions 6 (seed, drop-off), 15b (banner), 16, 17, 18, 20, and the Report state table.
- Tables: weekly reports (key: week start) and reported items (week start, repo key, ticket id, plain stage).
- Report state machine with the project's FSM pattern: none → drafted (draft), drafted → drafted (save; draft confirmed), drafted → sent (mark_sent), sent → drafted (undo_sent), sent + draft refused ("undo first").
- "Draft weekly report" builds text from stored data only (no AI, no network): subject `Ryan weekly update - MM/DD` (Friday of the week); "Key Accomplishments & Current Focus" per kind, Feature first by epic, one line per Shipped / Done / On staging / Building item from its Report line or title, with the plain stage in brackets; "Upcoming Milestones" with Waiting on you / Waiting on others items and the top ready ticket per Feature epic by priority. Carried-over items are in the same lists.
- Editable text area; Save per week; rebuilding replaces saved text only after a confirm; Copy copies subject and body.
- Mark as sent stores week, time, final text and stamps each source item as reported with its plain stage; Undo reverses it.
- Reported items that are Shipped or Done drop off; a reported item not Shipped that has new activity shows again.
- Seed: everything Shipped or closed by end of day Friday 2026-10-17 counts as reported.
- Banner when last week's report is not marked sent; it opens last week's page and draft (MM/DD = last week's Friday).

## Interfaces
Consumes the page model, `summary.report_line`, and the stages from the PR ticket. Produces sent-report data the page model reads for drop-off and Carried over.

## Acceptance
- [ ] Acceptance check 3 (second half): with the 10/17 seed, a ticket Shipped by then does not show.
- [ ] Acceptance check 4: draft, edit, save, mark as sent; reload keeps the text and the sent state; reported Shipped items are gone; Undo restores them.
- [ ] Acceptance check 5: subject `Ryan weekly update - 10/24` for the week of 10/20; both headings exact.
- [ ] One test per state-table row, including the refused draft while sent.
- [ ] Light and dark screenshots with the draft open.
