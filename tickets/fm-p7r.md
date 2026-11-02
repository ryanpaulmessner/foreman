---
id: fm-p7r
title: "Board: Config.ReloadJob DB checkout timeouts make CLI calls report 'foreman unavailable'"
type: bug
status: closed
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: 2026-10-30
close_reason: "Merged in PR #2 (7c5e0dc); live check 0 ReloadJob timeouts"
kind: internal
---

Seen 2026-10-21: the board stays up (same pid, /needs-you 200), but board.log has 137 Postgrex disconnects where Foreman.Config.ReloadJob timed out on a DB checkout. In the same window, `foreman wait` and a builder's `foreman ask` returned {"warning":"foreman unavailable; read was not queued"}, so a builder question was spooled and never reached Needs you, and coordinator waits ended without an answer.

## Acceptance
- [ ] Find why ReloadJob holds or waits on a connection long enough to time out (pool size, a long transaction, a lock) and fix it.
- [ ] Under the same load, `foreman wait` and `foreman ask` succeed; no ReloadJob timeouts in an hour of logs.
- [ ] A spooled ask is delivered when the board answers again (or the CLI says clearly that it was not delivered).

## Notes
- 2026-10-22 user: 2026-10-21: foreman wait with --timeout 7200 returned {"warning":"foreman unavailable; read was not queued"} while the board answered 200 and a --timeout 5 wait worked; other sessions use 3600. Suspect a server or CLI timeout cap below 7200, not a DB blip. The dispatch and foreman skills tell sessions to use 7200.
- 2026-10-30 user: Live check 2026-10-30: 20 minutes after deploy, 0 ReloadJob checkout timeouts and 0 [error] lines in board.log (was several per hour). Close after the push.
