---
id: fm-zgd.8
title: "Coordinator idle is not Needs you: only questions, permissions and usage limits raise a request"
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
close_reason: "Merged into main 3bbc5a2 (2026-10-19); board reloads it."
---

User request 2026-10-19. A Claude coordinator stops at the end of every reply, and the Stop hook (session_hooks.ex:57, facts("Stop") -> waiting/input) raises an "Input needed" session_waiting request each time. In a busy coordinator session (subagent and pi results waking it every few minutes) this gave a stream of Needs you items that resolved as "superseded, session resumed" moments later. The user does not want an idle coordinator in Needs you.

## Behaviour
- For coordinator and planning sessions, a plain Stop (reason input, no tool) records the session as waiting (state and a quiet marker on the session row / Focus) but creates **no** Needs you request.
- These still raise a request: AskUserQuestion (PreToolUse/PermissionRequest with that tool), any other PermissionRequest, and usage_limit (StopFailure).
- Pi build sessions keep today's behaviour unless the user decides otherwise (fm-3c3.5 / fm-3c3.9 cover pi waiting).
- Existing pending idle-input requests for the coordinator are resolved on deploy (or by the next resume).

## Acceptance
- Stop from the coordinator: no pending request, the Needs you count stays 0, and the session shows waiting.
- AskUserQuestion and PermissionRequest from the coordinator: one pending request, as today; it resolves on resume.
- usage_limit unchanged.
- Tests in the session hooks / SessionWaiting suites; mix precommit green.
