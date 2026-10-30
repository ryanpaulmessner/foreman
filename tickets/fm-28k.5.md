---
id: fm-28k.5
title: "New file tickets are not_found for about 20 s"
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

The on-demand sync in agent.ex:62-70 runs Beads.SyncJob, which skips file-ticket repos (beads/sync_job.ex:17), so a new ticket appears only on a file event or the 60 s rescan (reader.ex:27).
## Acceptance
- [ ] An unknown ticket id in a file-ticket repo triggers a sync of that repo before not_found.
- [ ] Test: foreman new then an immediate ask on it succeeds.
