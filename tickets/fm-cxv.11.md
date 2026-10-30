---
id: fm-cxv.11
title: "Check PR bases before open_pr"
type: feature
status: open
priority: 2
parent: fm-cxv
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: null
close_reason: null
---

Stacked PRs were merged into each other instead of staging on 10-20.
## Acceptance
- [ ] open_pr warns when the base is not the repo's target branch or the stack parent recorded for the ticket; after a merge, the board offers to rebase the next PR in the stack.
