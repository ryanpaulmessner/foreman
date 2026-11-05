---
id: fm-9mm.22
title: "Idle-timeout park closes the whole coordinator window, builds included"
type: bug
status: in_progress
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

Found by the fm-9mm.14 build review (2026-11-05). The observed idle_timeout park path still calls SessionTmux.park/2, which runs kill-window. A board-launched epic coordinator that idles out takes the pane builds in its window with it. This breaks spec rules R11 (close only the session's own pane) and R8 (builds keep running). The Park control (fm-9mm.14) already closes one pane through Foreman.SessionPane.close/2.

## Acceptance
- [ ] Idle-timeout park on a scratch epic coordinator with one pane build in its window closes only the coordinator's pane; the build pane keeps running (tmux test on a temporary socket).
- [ ] The attached-client guard on idle-timeout park still holds (test).
