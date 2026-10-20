---
id: fm-sr8.2
title: "Config hot reload on macOS (FSEvents)"
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
Config hot reload on macOS. Editing `~/.config/foreman/foreman.toml` updates the board live on Linux. On the Mac (2026-10-19) appending three `[[repos]]` entries did not reload: `board_config.loaded_at` stayed at the boot time until the board restarted.

## Lead
`Foreman.Config.Watcher` starts `FileSystem.start_link(dirs: [directory], recursive: false)`. The macOS backend (`mac_listener`, FSEvents) logged ``unknown option `{:recursive, false}`, ignore``. Check that the watcher receives FSEvents events for the file and that `Config.WatchMachine` accepts the event types FSEvents sends (they differ from inotify's).

## Acceptance
- [ ] On macOS, adding a repo to `foreman.toml` shows it on the board within 5 s with no restart
- [ ] A bad edit keeps the last good config and shows the error in Settings (MVP check 10) on macOS
- [ ] No backend warning in the log at startup
