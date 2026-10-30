---
id: fm-cxv.3
title: "Coordinators can record their own commit and push"
type: feature
status: open
priority: 2
parent: fm-cxv
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: null
close_reason: null
---

Coordinator-built work stays at stage queued, so ask push is refused not_committed (82 refusals in agent logs).
## Acceptance
- [ ] foreman commit <id> --sha accepts queued/building when the actor is claude (coordinator), recording the build as done by that session.
- [ ] Every stage refusal prints the current stage and the next command to run.
