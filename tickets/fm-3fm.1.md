---
id: fm-3fm.1
title: "How do coordinators pick their next ticket today, and where would a board nudge land?"
type: decision
status: closed
priority: 2
parent: fm-3fm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:research"]
created: 2026-11-04
closed: 2026-11-04
close_reason: "coordinators pick by hand via orient+dispatch and ignore board priority; build a new start-nudge machine on the close-out nag pattern; fold fm-c2w.27's skill parts in"
---

## Question

Read the orient and dispatch skills (~/dev/utils/skills: `orient`, `dispatch`, `ready-repos.py`), foreman ready and its ordering, the priority overrides and Jump to front (fm-c2w.23), the open follow-up fm-c2w.27, coordinator note delivery (`foreman note`, `delivered` / `skipped` for busy, ended or gone panes) and the close-out nag machine (fm-fdw). Answer: what a coordinator does today to choose its next ticket; what of the board's priority it ignores; what a nudge note must contain so a coordinator acts on it without asking Ryan; what happens to a note when the coordinator is busy; and whether fm-c2w.27 must ship before, with, or inside this effort.

## Notes
- 2026-11-04 user: Answer (research, branch research/plan-nudge 52baeba, docs/research/plan-nudge.md): orient recommends one ticket and dispatch launches only after Ryan says yes; nothing is automatic. foreman ready sorts by file priority then age and ignores board overrides and jumps (only ls --overlay returns them; no skill reads them). A start note must name ticket, repo, why next (initiative and rank), the commands, and a guard (launch only if the stage is queued); nothing blocks two launches today. Notes are never queued: typed only into an idle prompt; close-out nags retry busy after 10 min, ended or gone after 3 h, no fallback; main_coordinator/0 can return an ended row. Build a new machine on the close-out nag's structure. fm-c2w.27: its skill and ready changes fold into this effort; its two priority.ex fixes can ship first alone.
