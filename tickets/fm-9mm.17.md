---
id: fm-9mm.17
title: "Sessions page: the Tree with the Waiting on you strip"
type: task
status: closed
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.10","fm-9mm.12"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-05
close_reason: "PR #19 merged; deployed 2026-11-05, /sessions 200 with the nav link"
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 23-27 (step 3, option C) and the Note to all coordinators button.
- "Sessions" as the second nav item (`hero-rectangle-stack`, no count); `/sessions` with the repos sidebar.
- Waiting on you strip from the state function: at most 2 rows then "Show all <N>"; item copy from Decision 25.
- "All sessions" panel: outline tree (main -> epic coordinators -> builds), Unassigned group, columns per Decision 24, 820 layout, whole row links to `/sessions/:id`, Focus icon above the link.
- Collapsed coordinators in `localStorage` (wrapped reads and writes); Show ended (last 7 days) checkbox; R8 rows.
- Updates from `:sessions_changed`; the tree never runs `capture-pane`.
- Header button "Note to all coordinators": one text box, "Send note"; results "Sent to <N> coordinators." and "Not sent to <names>: the pane is closed."
- Every state and copy in the spec's Tree table: success, empty (with Start main coordinator), empty with Show ended, loading, tmux error, connection lost.

## Interfaces
- Consumes the state function, `:sessions_changed`, and the detail page route.

## Design pack
UI "Changed screens and their states"; mockup https://claude.ai/artifact/4UCbQNQ3NG55L29M7cJ8WD (option C).

## Acceptance
- [ ] At 1440 with 15 sessions (5 waiting) all waiting sessions and at least 11 rows show in the first view (spec acceptance 11).
- [ ] A session that waits on you shows in both the strip and the tree.
- [ ] LiveView tests with element ids for each state in the Tree copy table.
- [ ] verify ui at 1440 and 820, light and dark, every state.
