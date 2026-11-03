---
id: fm-9mm.5
title: "Session lifecycle statechart: states, events and the three user-facing labels"
type: decision
status: closed
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.1","fm-9mm.2"]
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:prototype"]
created: 2026-11-01
closed: 2026-11-02
close_reason: "Lifecycle table, labels and controls settled; R8 relaunch resumes coordinator; R9 undeliverable answers go to the coordinator"
---

## Question

Model one session's lifecycle with the `statechart` skill: starting, working, waiting on you (question, permission, usage limit), in review, idle, parked, ended (dead), resumed; for builds and coordinators. Show which board facts drive each event (stage events, requests, pane liveness from the monitor, Stop, Resume), which controls are allowed in each state, and how the many internal states collapse to the three labels **working / in review / waiting on you** plus idle and ended. Run the chart against the rules and show Ryan each rule that breaks. Inputs: session identity and Pi resume answers, session_machine.ex, external_session.ex, session_waiting.ex, stage.ex.

## Notes
- 2026-11-02 user: Resolved 2026-11-02 with Ryan (prototype: /statechart). State part of docs/specs/sessions-view.design.md holds the state table (starting, working, idle, waiting.question/permission/usage_limit, parked, ended), the label mapping (waiting on you > in review > working > idle > parked/ended), controls per state, and rules R1-R10. TLC: two-session model 1,792 states, one-build model 51 states. Hold: R1, R3-R6, R10 (R3-R5 by construction of the control table). Broke and settled: R2 open card on ended session -> an open card always makes the label 'waiting on you', 'ended' as a second line; R8 Relaunch build with dead coordinator -> Ryan: builds keep running under a dead parent ('parent ended' note), Relaunch build resumes the coordinator first, then sends the note; R9 answer cannot be delivered (no Pi session id or worktree removed) -> Ryan: answer goes to the parent coordinator as a note with the question, card closes; when the session can resume, answering resumes it first. Not modelled: R7 one live session per name. Rendered report: https://claude.ai/artifact/7Wqutsha9uYNtkox2JSaK3. Model files: chief-research session scratchpad statechart/ (Sessions.tla, Build.tla).
