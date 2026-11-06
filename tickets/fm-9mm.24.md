---
id: fm-9mm.24
title: "A build whose coordinator cannot resume has no Resume or Relaunch until Start fresh"
type: task
status: open
priority: 2
parent: fm-9mm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-05
closed: null
close_reason: null
---

Found by the fm-9mm.15 review (2026-11-05). Spec R10: a dead build always has a way back. When the build cannot resume and its coordinator ended and cannot resume, the page shows Relaunch build off ("<coordinator> ended and cannot resume.") and nothing else until Ryan presses Start fresh on that coordinator. Decide and build the path: for example offer Start fresh for the coordinator from the build's page, or send the relaunch note to the main coordinator.

## Acceptance
- [ ] A dead, non-resumable build under a dead, non-resumable coordinator offers one working control on its own page (LiveView test).
