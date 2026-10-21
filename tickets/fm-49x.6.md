---
id: fm-49x.6
title: "Epic target dates in Upcoming Milestones"
type: feature
status: open
priority: 2
parent: fm-49x
blocked_by: ["fm-49x.5"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: null
close_reason: null
---

## What to build
Epic target dates. Spec decision 19 and the epic-dates part of decision 16.
- Optional frontmatter `target` (ISO date) on epics; `foreman update <id> --target YYYY-MM-DD` sets it (and a way to clear it).
- The epic sub-heading on `/week` shows the date.
- "Upcoming Milestones" adds epics whose target is in the next 21 days, with the date.

## Acceptance
- [ ] CLI test: set, change, clear; a bad date is refused with a clear message; `foreman check` stays valid.
- [ ] Projection test reads `target`.
- [ ] Draft test: an epic due in 10 days is listed; one due in 30 days is not.
