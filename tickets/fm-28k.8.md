---
id: fm-28k.8
title: "Coordinator windows have no board session, so cards show Source unknown"
type: bug
status: in_progress
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

'Go to session' (request_context.ex:46 -> request_source.ex:5-43) resolves only planning rows, dispatch rows for the same ticket, and session_waiting facts. Coordinator windows started by the coord shell function have no row and no @foreman-session, and their FOREMAN_SESSION differs from the window name (filter-redesign vs filter-design, query-perf-coord vs query-perf). 369 of 509 cards in 14 days showed Source unknown; about 1% had a working button. Follows fm-knr.
## Acceptance
- [ ] A 'foreman session register' (name, tmux pane id, workdir, harness) that the coord function and slice-loop/relay open call.
- [ ] Source resolves by the card's session name first, then falls back to a live tmux window/pane with that name or @foreman-session tag.
- [ ] Test with a coordinator-registered card: Go to session targets its pane.
