---
id: fm-qxp
title: "Coordinator can withdraw its own pending Needs you request"
type: task
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

The request state machine has a withdraw event (pending -> withdrawn) but no CLI verb or UI action uses it. A coordinator that asks a question and then gets the answer elsewhere (chat) cannot remove the stale card; Ryan keeps seeing it (card e3e8a41f, 2026-10-21).

## Acceptance
- [ ] `foreman withdraw <request-id> --reason "..."` moves a pending request to withdrawn; refused for any other state.
- [ ] The card leaves Needs you; Recent outcomes shows it as withdrawn with the reason.
- [ ] A `foreman wait` on it returns state withdrawn.
