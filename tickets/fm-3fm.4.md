---
id: fm-3fm.4
title: "When does the board nudge a coordinator, how often, and when does it stop?"
type: decision
status: open
priority: 2
parent: fm-3fm
blocked_by: ["fm-3fm.1","fm-3fm.2","fm-3fm.3"]
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:prototype"]
created: 2026-11-04
closed: null
close_reason: null
---

## Question

A statechart for the nudge, per initiative: the event that starts it (next piece ready and the initiative in the top N), the first-nudge delay and the repeat interval, what stops it (dispatch recorded, initiative drops below N, Ryan pauses it), what happens when the note is skipped (busy, ended, gone pane) and when the coordinator has no live session (goes to the main coordinator, per the map Notes), and how it avoids nudging two coordinators for one ticket. Reuse or extend the close-out nag machine if the research says so. Model-check the rules and let Ryan react to the chart.
