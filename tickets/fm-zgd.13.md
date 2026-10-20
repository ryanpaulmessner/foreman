---
id: fm-zgd.13
title: "macOS notifications from the board server for new Needs you items (no browser tab needed)"
type: feature
status: closed
priority: 2
parent: fm-zgd
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: 2026-10-19
close_reason: "Merged into main 6ea084d; CLI rebuilt (ask decision --doc)."
---

User 2026-10-19: not getting OS notifications for new inbox items. Diagnosis: browser notifications need (1) a board tab open, (2) site permission granted for that exact origin (Chrome showed Notification.permission = 'default' for http://127.0.0.1:4747; localhost:4747 is a different origin), (3) macOS allowing Chrome notifications. Easy to miss all three.

Since the board runs locally (launchd), have the server post a native notification when a request becomes pending (decision, push, open_pr, merge, session_waiting incl. question): title '<Kind> · <ticket>', body the question or first line, sound optional. macOS: osascript 'display notification' (built in; no click action), or terminal-notifier if installed (-open http://127.0.0.1:4747/needs-you?…; do not install it without asking). Config: board.os_notifications (default on for macOS), off on Linux unless notify-send exists. Dedupe per request id (one notification per request), never for requests created before boot. Keep the browser path as is. Tests with a stubbed runner; mix precommit only base env failures.
