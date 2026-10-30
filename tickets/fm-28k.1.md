---
id: fm-28k.1
title: "foreman wait ends at once when one poll fails"
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

One failed 2 s poll (cli_transport.ex:67) returns a body with no state; RequestWait.resolved?/2 (request_wait.ex:15) treats any state not in pending/approved/executing as resolved, so a 7200 s wait returns 'foreman unavailable' immediately. Agents loop 600 s waits to work around it.
## Acceptance
- [ ] A poll with no state (transport error, 5xx, timeout) is retried until the deadline; only a real terminal state or the deadline ends the wait.
- [ ] Test: one failed poll then an answered state returns the answer.
