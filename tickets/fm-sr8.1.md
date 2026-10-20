---
id: fm-sr8.1
title: "launchd services and macOS install docs"
type: feature
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
launchd equivalents of `deploy/systemd/` for macOS, plus a macOS install section next to it: user agents for web and worker (or one `FOREMAN_ROLE=all` agent) running the release at `~/.local/lib/foreman/current`, environment files under `~/.config/foreman`, logs under `~/Library/Logs/foreman`. Planning sessions use the user's default tmux server here (see the socket ticket), so no `foreman-tmux` agent is needed.

## Observed on the Mac (2026-10-19)
- `launchctl bootstrap` from a non-login shell left agents `pended nondemand spawn = speculative`, `runs = 0` (board and Homebrew's caddy agent); `launchctl kickstart` started them.
- After a crash, KeepAlive respawn stayed `pended nondemand spawn = inefficient` with `ProcessType` Background and with Standard. Workaround: `~/.config/foreman/board.sh` restarts `mix phx.server` in a loop; recovery after `kill -9` takes about 10 s.
- Agents have no shell profile: PATH must name asdf shims, `~/.local/bin` (claude, bd), Homebrew (tmux, gh).
- Not yet verified: RunAtLoad at a real login.

## Acceptance
- [ ] Documented install: build release, environment files, plists, `launchctl bootstrap`/`kickstart`, uninstall
- [ ] Board answers after login without a manual start (checked across a real logout/login or reboot)
- [ ] Board answers within 30 s after `kill -9` of the BEAM, without a wrapper loop, or the docs keep the loop and say why
- [ ] Launched panes and the coordinator get the user's login environment (claude, foreman, git on PATH)
