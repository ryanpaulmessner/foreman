---
id: fm-28k.3
title: "Closing a ticket supersedes its decision cards"
type: bug
status: in_progress
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

requests.ex:326 supersedes every pending request kind when a ticket closes. 6 decisions were lost in 14 days (e.g. the n7p.7 'show Arnoldo' card). Docs (foreman SKILL.md:119) only promise this for push and open_pr.
## Acceptance
- [ ] Close supersedes only push, open_pr and merge requests; decision and other kinds stay pending.
- [ ] Test for both.
