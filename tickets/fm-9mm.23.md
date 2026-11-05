---
id: fm-9mm.23
title: "Queue a note to a busy coordinator until its prompt is idle"
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

Found by the fm-9mm.15 review (2026-11-05). R9 answers and Relaunch build notes go to a coordinator by typing into its pane, only when its prompt is idle. When the coordinator is mid-turn, the answer is refused ("The board could not send it: <name> is busy. The card stays open.") and Ryan has to answer again later. Nothing queues the note.

## Acceptance
- [ ] An answer to an ended build's card while its coordinator is busy is saved and the note is typed when the coordinator's prompt next goes idle, on a declared Foreman.Fsm machine (test).
- [ ] The card shows that the note waits for the coordinator, and the line changes when it is sent.
