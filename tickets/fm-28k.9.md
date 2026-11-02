---
id: fm-28k.9
title: "Dispatch rows take the caller's session name"
type: bug
status: closed
priority: 2
parent: fm-28k
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: 2026-10-30
close_reason: "Merged in PR #1 (f141b5b), reviewed, tests green vs baseline"
---

cli.ex:198 stores FOREMAN_SESSION of the caller on dispatch, so when a coordinator dispatches a build its own later cards resolve to the Pi pane.
## Acceptance
- [ ] dispatch records the build's session from --session (required), never the caller's env.
- [ ] Test: a coordinator card after a dispatch still resolves to the coordinator.
