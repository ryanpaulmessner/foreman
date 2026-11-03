---
id: fm-zgd.10
title: "Idea: in-browser terminal mirror of a session (later)"
type: feature
status: open
priority: 2
parent: fm-zgd
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: null
close_reason: null
---

User idea 2026-10-19, explicitly down the road: show a live mirror of a session's tmux pane in the board (read, and maybe type), so Needs you items can be handled without switching to the terminal. Follows fm-zgd.9 (Open session button + inline AskUserQuestion answers). Capture only; no design yet. Open questions: read-only vs interactive, security of a browser-to-pane input path, xterm.js over a LiveView/websocket stream of capture-pane or a pipe-pane feed.

## Notes
- 2026-11-03 claude: 2026-11-03: the read-only half (pane output on the session page) is built in fm-9mm.13. This ticket now covers only typing into a pane from the browser (later).
