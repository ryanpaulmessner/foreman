---
id: fm-c2w.22
title: "Run the board from a release, not the live source checkout"
type: task
status: open
priority: 2
parent: fm-c2w
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: null
close_reason: null
---

2026-10-19: the board runs mix phx.server (dev, code reloader) from ~/dev/foreman. Merging into that checkout hot-recompiled modules under the running app: twice today it broke the board (corrupt atom table while an escript build raced the reloader; SessionMonitor called Foreman.Sessions while it was unloaded -> app shutdown with the VM still up, so board.sh never restarted it). README already describes a release under ~/.local/lib/foreman. Change board.sh / the launchd agent to run the release (MIX_ENV=prod or a dedicated env with the same config/DB), add a deploy script (build release from main, run migrations, swap, kickstart), and make board.sh restart when the app exits even if the VM stays up. Ryan allows agents to kickstart the board when it crashes.
