---
id: fm-c2w.27
title: "Orient and dispatch act on board priority: jumps first, overrides carried into ticket files"
type: task
status: open
priority: 1
parent: fm-c2w
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-20
closed: null
close_reason: null
---

From the fm-c2w.23 review (2026-10-20). The board now has priority overrides and Jump to front (foreman ls --overlay --json returns jumps and priority_overrides), but the orient and dispatch skills (~/dev/utils/skills) and foreman ready read only the files, so a jump changes how the board looks but not what the coordinator picks next. Change: orient lists pending jumps first and recommends them; dispatch's ready-repos honours board overrides; the coordinator carries an override into the ticket file with foreman update --priority (the next sync then clears the override); orient's Needs you wording says priority then oldest. Also (review minors): store the file value at override time so a later deliberate file edit wins; guard the override delete by value against a sync/edit race (priority.ex clear effect).
