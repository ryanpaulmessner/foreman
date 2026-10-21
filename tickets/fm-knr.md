---
id: fm-knr
title: "Needs you cards name their source build and jump to its session"
type: feature
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

Ryan, 2026-10-21: a card such as 'May we enable the local login bypass for the KPI preview…' does not say which build asked it, and he cannot get to that session from the card. It came from the kpi-countup Pi build (tmux window kpi-countup, pane %464, ticket work-ani).

The board already knows the session for dispatched builds (FOREMAN_SESSION, window/pane metadata from pi-window). Relay builds (slice-loop) do not register with the board at all, so their cards have no session.

## Acceptance
- [ ] Every request card shows its source: build name, ticket, repo, and harness (pi/claude), when known.
- [ ] A 'Go to session' action focuses that tmux window/pane (switch-client + select-window/pane on the board's tmux server or the default one), or copies the exact command when the board cannot focus it.
- [ ] Relay-opened builds register a session with the board (name, pane, workdir) so their cards get the same link.
- [ ] A card from an unknown session says 'source unknown' instead of nothing.
