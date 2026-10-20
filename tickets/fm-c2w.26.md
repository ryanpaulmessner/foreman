---
id: fm-c2w.26
title: "Unplanned shows only untouched tickets; parentless work in flight gets its own place"
type: feature
status: closed
priority: 2
parent: fm-c2w
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-20
closed: 2026-10-20
close_reason: "fb71b58 on main: Unplanned = never started; Standalone work = other open parentless tickets; 49 tests"
---

Ryan 2026-10-20: Unplanned should hold only unspecced, unstarted items, but many rows there show a stage (dispatched, building, committed...). Cause: Initiatives.Tree (lib/foreman/initiatives/tree.ex:60-66) puts every non-epic ticket without an epic, link or discovered-from edge into orphans, whatever its stage or status. Change: Unplanned = parentless tickets that are open and still queued (never dispatched, not in_progress). Parentless tickets that are in flight (dispatched..committed, or status in_progress) move to a new 'Standalone work' section above Unplanned (one-off fixes have no epic by design), with the same row format; check they also appear in the In flight view. Closed tickets appear in neither. Counts in the headers follow. LiveView tests for each bucket. Do after fm-c2w.25 (same file).
