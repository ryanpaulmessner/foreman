---
id: fm-zgd.18
title: "Forge sync links a PR to every ticket id in its description"
type: bug
status: open
priority: 2
parent: fm-zgd
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-04
closed: null
close_reason: null
---

Found 2026-11-04: PR #14 (fm-zgd.17.3) says "until fm-zgd.17.4" in its description. Forge sync (`Foreman.Forge.Stack.links/2` scans title, branch and body) linked PR #14 to fm-zgd.17.4 too, moved it to pr_open then merged when #14 merged, refused its real dispatch, and suggested closing it. Fixed by hand: abandon, revive, dispatch again.

A mention is not ownership. Decide which fields link a PR to a ticket (branch and title only, or a "Ticket:" line in the body), and treat other ids in the body as mentions only.

## Acceptance
- [ ] A PR whose body only mentions another ticket id does not change that ticket's stage (test).
- [ ] A PR still links to the ticket in its title or branch (existing tests).
