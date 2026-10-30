---
id: fm-28k.2
title: "/week crashes on every board event"
type: bug
status: open
priority: 2
parent: fm-28k
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: null
close_reason: null
---

WeekLive.handle_info/2 (week_live.ex:12) only matches :refresh_week, so any other PubSub message crashes the LiveView (35 crashes in board.log).
## Acceptance
- [ ] Catch-all handle_info ignores other messages; test sends an unrelated message and the page stays up.
