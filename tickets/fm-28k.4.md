---
id: fm-28k.4
title: "File-ticket epic stays a ticket after its file changes to type epic"
type: bug
status: open
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

overlay.ex:52 sets the epic-or-ticket classification once, at first backfill. work-q76 was backfilled 2026-10-26 as a ticket, later changed to type: epic; agent.ex:41-51 still refuses 'epic ticket' with beads_epic_required (37 refusals in agent logs).
## Acceptance
- [ ] Every sync reclassifies from the current file type.
- [ ] The refusal names file tickets correctly (no 'beads' wording when the repo uses tickets/).
- [ ] Test: ticket -> epic file change, then the epic link succeeds.
