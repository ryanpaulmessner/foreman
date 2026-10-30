---
id: fm-sr8.4
title: "Focus switches the user's terminal to the session"
type: feature
status: in_progress
priority: 2
parent: fm-sr8
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: null
close_reason: null
---

## What to build
The board's Focus button must show the session in the user's terminal. `SessionTmux.focus/2` runs only `select-window`, which changes the active window inside the target session; when no client is attached to that session (the normal case on one tmux server, where the user sits in their own session) nothing visible happens. User report 2026-10-19: "none of the buttons on the foreman webapp for the coordinator session do anything" (Focus; Relaunch and Start fresh are disabled while running, by design, which also reads as broken).

Local uncommitted edit on the Mac: after `select-window`, `focus` lists clients (`#{client_activity} #{client_name}`) and runs `switch-client -c <most recent> -t <window>`; with no client it returns `:ok` as before. Untested in the browser.

## Acceptance
- [ ] Focus on the coordinator and on a launched ticket switches the most recently active client to that window
- [ ] No attached client: Focus succeeds and says no terminal is attached, with the attach command
- [ ] Disabled Relaunch/Start fresh show why (tooltip or state text)
- [ ] Tests for both focus paths against a scratch tmux server
