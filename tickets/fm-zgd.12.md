---
id: fm-zgd.12
title: "CLI: let the asking agent withdraw its own stale request"
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

2026-10-19: agents posting decision cards (new inbox rule) leave stale duplicates when a question is answered elsewhere (chat, another card). Request.ex already has :withdraw (pending -> withdrawn) but no CLI/API path calls it, so only the user can clear them (Answer/Decline). Add 'foreman withdraw <request-id> [--note]' allowed for the same actor+session that asked; refuse others. Card disappears from Needs you with outcome 'withdrawn'. Tests + mix precommit.
