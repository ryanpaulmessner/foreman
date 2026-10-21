---
id: fm-p7r
title: "Board: Config.ReloadJob DB checkout timeouts make CLI calls report 'foreman unavailable'"
type: bug
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: null
close_reason: null
kind: internal
---

Seen 2026-10-21: the board stays up (same pid, /needs-you 200), but board.log has 137 Postgrex disconnects where Foreman.Config.ReloadJob timed out on a DB checkout. In the same window, `foreman wait` and a builder's `foreman ask` returned {"warning":"foreman unavailable; read was not queued"}, so a builder question was spooled and never reached Needs you, and coordinator waits ended without an answer.

## Acceptance
- [ ] Find why ReloadJob holds or waits on a connection long enough to time out (pool size, a long transaction, a lock) and fix it.
- [ ] Under the same load, `foreman wait` and `foreman ask` succeed; no ReloadJob timeouts in an hour of logs.
- [ ] A spooled ask is delivered when the board answers again (or the CLI says clearly that it was not delivered).
