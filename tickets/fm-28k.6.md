---
id: fm-28k.6
title: "board.log grows without limit at debug level"
type: bug
status: closed
priority: 2
parent: fm-28k
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: 2026-10-30
close_reason: "Merged in PR #1 (f141b5b), reviewed, tests green vs baseline"
---

~/Library/Logs/foreman/board.log is 15 GB (2026-10-30): debug level, no rotation.
## Acceptance
- [ ] Prod/board runs at info level.
- [ ] Rotation (newsyslog or the launchd wrapper) keeps a bounded size; documented in deploy/.
