---
id: fm-hwc
title: "Board drops CLI requests for a few seconds several times an hour"
type: bug
status: open
priority: 1
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-04
closed: null
close_reason: null
---

Seen 2026-11-04 afternoon, five times in about 3 hours: `foreman ask` returned "foreman unavailable; event spooled for replay" or "foreman and spool unavailable; event not saved", while Needs you loaded a few seconds later. Once the "not saved" ask was in fact saved (a5ebb5b6); once it was not (cce5d236). Cards spooled earlier landed late, so a retry loop could post a duplicate (704e2ae8, withdrawn).

Suspects, not checked: the code reloader recompiling after merges into ~/dev/foreman; Postgres near max_connections (282/300 at one point, mostly other worktrees' test databases); the new lifecycle writes (one UPDATE per working session per 3 s tick).

## Acceptance
- [ ] Root cause found and named (board log, Postgres stats).
- [ ] "event not saved" is only printed when the request is really not saved (test).
- [ ] No CLI request fails during a normal hour with 10 working sessions (measured).

## Notes
- 2026-11-05 claude: 2026-11-05 18:29: ask review_ui printed 'foreman and spool unavailable; event not saved' but request 687c8bbb was saved and pending in approval_requests. The warning is wrong in this case too; the board answered 200 at the same time.
