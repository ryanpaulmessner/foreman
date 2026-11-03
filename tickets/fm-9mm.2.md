---
id: fm-9mm.2
title: "Can a Pi build session be resumed in its worktree after its pane closes?"
type: decision
status: closed
priority: 2
parent: fm-9mm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:research"]
created: 2026-11-01
closed: 2026-11-01
close_reason: "Pi can resume via pi --session-id; record the id at launch; Resume only when id, worktree and session file exist"
---

## Question

Find out whether Pi can resume an earlier session (its conversation and context) in the same worktree after the tmux pane is gone: the command, what id it needs, where Pi stores sessions, and what breaks (expired context, model change). Also check what Claude Code needs to resume a conversation by id (`claude --resume <uuid>`) and how foreman's relaunch already does it (session_machine.ex, sessions.ex relaunch). The answer decides whether a dead build view offers Resume or only 'Relaunch build on this ticket'.

## Notes
- 2026-11-01 user: Resolved 2026-11-01 (research). Yes: Pi 1.0.0 stores sessions under ~/.pi/agent/sessions/<cwd>/ and `pi --session <id>` from the same worktree restores conversation, model and thinking level (compacted sessions too). Foreman cannot resume today: pi-window starts `pi --name` with a random id and the registry stores no Pi session id. Breaks on resume: Bifrost model pin is memory-only (coordinator re-pins), unavailable model falls back with a warning, wrong cwd forks or starts empty, deleted worktree fails, pi-wait / foreman wait processes must restart. Recommendation: pi-window generates a UUID and runs `pi --session-id <uuid>`; `foreman session register` gains --pi-session. Dead build shows Resume only when the id is recorded, the worktree exists and the session file exists; otherwise only 'Relaunch build on this ticket'. Coordinators already do this with claude --session-id / --resume. Unverified: cross-provider thinking replay, subscription login at resume, mid-turn loss, --model re-pin on resume. Findings: research/pi-resume branch, docs/research/pi-resume.md, commit d8ba718 (worktree ~/dev/foreman-worktrees/research-pi-resume, local only).
