---
id: fm-j73
title: "Code reload after a merge can shut the board down"
type: bug
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-05
closed: null
close_reason: null
---

Found 2026-11-05 deploying PR #18 (code only) with git merge in ~/dev/foreman. The code reloader recompiled; while Foreman.Sessions was being recompiled, Foreman.SessionMonitor polled and crashed with UndefinedFunctionError (Foreman.Sessions.reconcile/1, module not available), again and again until the supervisor gave up: board.log ends with '[notice] Application foreman exited: shutdown'. The beam process stayed up, so board.sh did not restart it; port 4747 answered nothing until launchctl kickstart. Code-only deploys are expected to need no restart.

## Acceptance
- [ ] A merge that recompiles Foreman.Sessions while the board runs leaves the board serving pages (no application shutdown), or board.sh restarts the app when it exits.
- [ ] A test or a scripted reload on a scratch board shows it.
