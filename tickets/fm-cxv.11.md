---
id: fm-cxv.11
title: "Check PR bases before open_pr"
type: feature
status: closed
priority: 2
parent: fm-cxv
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: 2026-11-02
close_reason: "Merged to main via PR 4 (2026-11-02); live on the board since 83066bb."
---

Stacked PRs were merged into each other instead of staging on 10-20.
## Acceptance
- [ ] open_pr warns when the base is not the repo's target branch or the stack parent recorded for the ticket; after a merge, the board offers to rebase the next PR in the stack.
