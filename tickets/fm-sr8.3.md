---
id: fm-sr8.3
title: "Coordinator workdir and planning tmux server from the environment"
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
Make the coordinator working directory and the planning tmux server configurable at runtime, and default them sensibly per host.

Today `Foreman.Sessions` defaults `:coordinator_workdir` to `~/dev/music` and `SessionTmux` defaults `:planning_tmux_socket` to `foreman`, with no environment override for either (`FOREMAN_EXTERNAL_TMUX_SOCKET` exists for pi windows only). On the work Mac there is no `~/dev/music`, and the user wants one tmux server: coordinator and launched sessions on the default server.

Local uncommitted edit on the Mac, in the style of `FOREMAN_CONFIG_DIR`: `config/runtime.exs` reads `FOREMAN_COORDINATOR_WORKDIR` (default `~/dev/music`) and `FOREMAN_PLANNING_TMUX_SOCKET`. The dotfiles `coord` alias also hard-codes `~/dev/music` and `-L foreman`; on the Mac it is replaced by a `coord` function in `~/.aliases.local` that creates the `coordinator` session if missing (running `foreman coordinator`), then `switch-client` inside tmux or `attach` outside.

## Acceptance
- [ ] Both settings come from the environment, documented in the README with the other `FOREMAN_*` variables
- [ ] With `FOREMAN_PLANNING_TMUX_SOCKET=default`, Launch opens the project session on the default server and the coordinator CLI accepts a `coordinator` session there
- [ ] Defaults keep the personal machine's behaviour unchanged
- [ ] Dotfiles `coord` works from inside or outside tmux and runs `foreman coordinator` when it creates the session (dotfiles change, separate commit)
