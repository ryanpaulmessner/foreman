---
id: fm-9mm.6
title: "Sessions tree page: layout, grouping and states"
type: decision
status: in_progress
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.4","fm-9mm.5"]
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:prototype"]
created: 2026-11-01
closed: null
close_reason: null
---

## Question

Design the Sessions page: the tree (main coordinator → epic coordinators → builds, an Unassigned group), what each row shows, the state labels and colours, header counts (Working N, Waiting N), the Ended filter, row actions, and where the page sits in the nav (`information-architecture`). Build 2-3 variants from the board's real CSS and markup, publish them as an Artifact, run `ux-critique` and `ux-laws` on them before Ryan reacts, and record the chosen variant with its empty, loading, error and success states (`ui-patterns`).

## Notes
- 2026-11-03 user: 2026-11-03 Ryan picked C, outline tree with a Waiting-on-you strip (card 4c559f93). The critique's left-open items are decided as planned: strip capped at 2 rows plus 'Show all N'; collapsed coordinators remembered in localStorage; a waiting session shows in the strip and the tree, both from one state function. Option D 'All sessions grid' (Ryan's Chief-style ask) added to the mockup and critique the same day; whether it ships as a Tree/Grid switch is on card 8a7f4f44.
- 2026-11-03 user: 2026-11-03: Ryan picked 'Switch, Tree first' (card 8a7f4f44): one Sessions page with a Tree · Grid switch; Tree (C) shows first and the board remembers the choice. Tree ships first; Grid (D) ships after Tree and the detail page. Grid reads only on-screen cards, every 3 s (idle 30 s), one tmux call per check.
