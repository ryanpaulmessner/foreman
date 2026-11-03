---
id: fm-3c3.8
title: "Launch an epic coordinator for a ticketed epic"
type: feature
status: closed
priority: 2
parent: fm-3c3
blocked_by: ["fm-3c3.7"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: 2026-11-03
close_reason: "Superseded by fm-9mm.18 (one-click Launch coordinator on epics, Sessions spec Decisions 28-31)."
---

Ticketed epics that are not in flight (fe-lwp, fe-813, cdo-*) have no way to restart from the board. Reverses the launcher spec's non-goal "launching sessions for tickets inside a ticketed epic" (user decision 2026-10-18).

## Behaviour
- Ticketed epics (stage ticketed or derived building/shipping, not done/abandoned) get Launch / Focus / Relaunch like draft epics and unplanned tickets: one Claude window per epic in the project's tmux session on `tmux -L foreman`, tracked, parked after the idle limit, Relaunch resumes the conversation.
- Opening prompt: the epic coordinator owns that epic's builds. It orients on the epic (its ready tickets, in-flight and reported tickets, open requests), then runs the `dispatch` skill for the epic's frontier and closes out under the usual rules (review, commit only when asked, board requests for push/PR/merge). It does not touch other epics. Keep the prompt short; it names skills rather than restating them.
- The main coordinator (`foreman coordinator`) is unchanged.
- Pi windows the epic coordinator dispatches land on the foreman server in that epic's project session, not the user's default tmux server.

## Acceptance
- Launch on a ticketed epic opens a window named by the epic id in the project's session (scratch tmux, stub claude printing argv and prompt); the prompt names the epic and the dispatch skill.
- Focus/Relaunch/parking behave as for planning sessions (existing tests extended, not duplicated).
- Done or abandoned epics show no Launch.
- Board screenshot (light/dark, desktop and 390px) shows the control on an epic row and the epic page.
- `mix precommit` green.

## Notes
- 2026-10-19 user: User 2026-10-18: the epic coordinator's pi builds open as new panes in the epic coordinator's own window, not new windows (dispatch pane mode, skills sk-fkb). The opening prompt tells the epic coordinator to dispatch in pane mode; Focus on a building ticket selects its pane. Main coordinator keeps windows.
- 2026-10-19 user: sk-fkb merged: pane builds send their %pane-id through the existing dispatch --window field (FOREMAN_SESSION stays the logical name). Focus must treat a %-prefixed window value as a pane: select-window then select-pane.
