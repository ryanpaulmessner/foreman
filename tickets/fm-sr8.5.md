---
id: fm-sr8.5
title: "session_tmux_test renamed-window liveness fails on macOS"
type: bug
status: open
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
`test/foreman/session_tmux_test.exs:254` ("manually renamed windows cannot crash liveness polling") fails on macOS (tmux 3.x from Homebrew), with and without local changes: `Tmux.observe/2` returns `{:ok, %{state: :starting, window: "@0"}}` where the test expects `{:ok, :window_gone}`.

## Acceptance
- [ ] Cause found (rename/automatic-rename behaviour, pane command naming, or timing on macOS tmux)
- [ ] Fixed in the code or the test setup, not skipped on macOS
- [ ] `mix test` green on macOS and Linux
