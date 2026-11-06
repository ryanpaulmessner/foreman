---
id: fm-9mm.15
title: "Session page: ended-session controls (Resume, Relaunch build, Start fresh) and answers to ended sessions"
type: task
status: closed
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.14"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-06
close_reason: "PR #23 merged (merged on GitHub; board merge stuck on fm-9i7); deployed"
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 17 (dead rows), 20, R8, R9, R10.
- Resume: Claude `--resume <id>`, Pi `--session-id <id>` in its worktree; same row, new `pane_id`; Pi opens in a new pane of its live parent's window, else a new window (Decision 20). Off reasons from the table.
- Relaunch build on this ticket: resume the parent first when it is dead (R8), then send it the relaunch note.
- Start fresh (dead coordinator, not resumable): in-page confirm; new row with the same name and parent; live builds of the old row move to it.
- R9: answering a card of an ended session resumes it first when it can, else sends the parent coordinator a note with the question and answer and closes the card.
- Panel copy for each dead state in the copy table.

## Interfaces
- Consumes the machine events resume, start_fresh, relaunch_build and the R9 routing hook on request answers.

## Acceptance
- [ ] R9: a build with an open card stops and cannot resume; answering sends the parent a note with question and answer and closes the card (spec acceptance 9).
- [ ] R8: Relaunch build on a dead build whose coordinator is dead resumes the coordinator first, then sends the note (spec acceptance 10).
- [ ] Start fresh moves live builds to the new row; the old row stays in history.
- [ ] Context tests for Resume (both harnesses, with stubs), Relaunch build, Start fresh; no real coordinator or build is started.
- [ ] verify ui of each dead panel state at 1440 and 820, light and dark.
