---
id: fm-9mm.20
title: "Ask resolution fails when the board and external tmux sockets are the same server"
type: bug
status: closed
priority: 1
parent: fm-9mm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-04
closed: 2026-11-04
close_reason: "Merged in PR #9 (a0fb42c); live check: push card 03d635f2 from foreman-board pane %668 carried no unknown-session warning"
---

Found 2026-11-04 after fm-9mm.9 deployed. Ryan's board.sh sets FOREMAN_PLANNING_TMUX_SOCKET=default and FOREMAN_EXTERNAL_TMUX_SOCKET=default (one tmux server). `AgentSessions.server_for_socket/1` checks the planning socket first, so every caller on that server maps to "board", while `session register` rows are stored as "default". The name match is then rejected as "another server" and the pane fallback finds nothing: cards from registered coordinators show the unknown source (foreman-board 2e5ade4d, ai-chat, filter-redesign). New dispatch rows are stored as "board" (sessions-launch).

## Fix
When both sockets name one tmux server, "board" and "default" are the same server for resolution, pane lookup and liveness. No data rewrite.

## Acceptance
- [ ] With both sockets set to one name, an ask from a registered coordinator pane resolves to its row (test).
- [ ] A build that inherited its coordinator's name still does not resolve to the coordinator (test, same config).
- [ ] With different sockets, behaviour is unchanged (existing tests).
