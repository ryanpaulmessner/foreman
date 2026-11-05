---
id: fm-9mm.21
title: "Session page says 'round 1' for coordinators"
type: bug
status: closed
priority: 2
parent: fm-9mm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-04
closed: 2026-11-05
close_reason: "Fixed in PR #17 (72a31dd): coordinators show no round"
---

Found 2026-11-04 on the live board after PR #13: /sessions/<foreman-board> (an epic coordinator) shows "Round 1 · output just now" and "Working on round 1." Coordinators have no review rounds; the round line and panel text should apply to builds only. Spec Decision 10 second lines.

## Acceptance
- [ ] A working coordinator shows no round in its second line or panel (LiveView test).
