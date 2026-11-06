---
id: fm-9i7
title: "Merge retry after a failed attempt reuses the failed action"
type: bug
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-06
closed: null
close_reason: null
---

## What happens
A merge card for a PR whose head SHA already has a failed `merge_actions` row returns that row (state failed) and never tries again. `Foreman.Merge.enqueue/3` inserts with `on_conflict: :nothing` on `[:remote, :number, :head_sha]` and only enqueues the job when a row was inserted.

## Seen
2026-11-06: PR #23, head 6b0334b. The first merge ran about 20 s after a push, while GitHub still reported mergeable as unknown, and failed `not_mergeable` (action 27). GitHub then said MERGEABLE and CLEAN. A second merge card (dd47478e) failed at once with the same action 27.

## Fix
A failed attempt must not block a new one for the same head: reset the row to merging and enqueue, or insert a new row. Also consider waiting for a non-unknown mergeable state before the first attempt.

## Acceptance
- [ ] A second merge request for the same head after a failed attempt runs a new merge job.
- [ ] A merge request for a head with a merging or merged action still does not start a second job.
