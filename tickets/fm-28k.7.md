---
id: fm-28k.7
title: "Tests leave tmux socket files behind"
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

2,723 stale tmux sockets in /private/tmp/tmux-504 from test servers.
## Acceptance
- [ ] Tests that start a tmux server kill it and remove the socket on exit.
