---
id: fm-sr8
title: "macOS host support: run foreman on a Mac with the systemd guarantees"
type: epic
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: null
close_reason: null
---

# macOS host support

User request 2026-10-19: foreman runs on Ryan's work Mac (macOS 26, Apple silicon, Homebrew, Postgres 18), not only on Linux/WSL with systemd. Each child names what failed on that Mac and the local workaround in use now.

## Goal

Install and run foreman on macOS with the same guarantees as the systemd setup: the board is up at login and after a crash, config edits reload live, the launcher and coordinator work on the user's normal tmux server, and the suite passes.

## Workarounds in use on the Mac (2026-10-19)

- Board: launchd agent `~/Library/LaunchAgents/com.ryanpaulmessner.foreman.plist` runs `~/.config/foreman/board.sh` (explicit PATH/env, `mix phx.server` in dev mode, its own restart loop).
- One tmux server: `FOREMAN_PLANNING_TMUX_SOCKET=default`, `FOREMAN_EXTERNAL_TMUX_SOCKET=default`; `coord` is a shell function in `~/.aliases.local`.
- Local uncommitted edits in `config/runtime.exs` and `lib/foreman/session_tmux.ex` (see children).
- http://foreman.local through Caddy on :80.

## Non-goals

- Beads journal-lock observation (`Foreman.Beads.JournalLock` reads `/proc/locks`, Linux only). It defers as `:indeterminate` on macOS; no beads repos are registered on the Mac.
- Windows-native support.
