---
id: fm-c2w.24
title: "Preview button on PR rows and tickets: start devserve, wait, open the page in a new tab"
type: feature
status: open
priority: 1
parent: fm-c2w
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-20
closed: null
close_reason: null
---

Ryan 2026-10-19: from the board, one click starts a dev server for a PR branch or ticket, waits for it, and opens it in a new tab.

Today: ticket detail and the PR page already have Preview Start / Open preview / Stop / Follow logs (lib/foreman_web/components/preview_controls.ex, Foreman.Previews, Previews.Devserve adapter). Gaps:
1. Blocked on sk-bso (devserve tmux backend, built, in review) and its setup: devserve on PATH, ReportSystem .env 0600, base DB refresh, apps.toml entry; ReportSystem PR #352 so PORT is honoured.
2. Previews.worktree/1 uses only the latest session's workdir. A PR with no build session (opened by hand, or a teammate's PR) has no preview. Resolve the worktree from code_path: find the worktree that has the PR head branch checked out (git worktree list --porcelain); if none, create one with the wt rules (--no-track, deps/.env symlinks, own _build) after an inline confirm.
3. Open in a new tab: browsers block window.open after an async wait. On click, open a board page /previews/<id> in a new tab at once (user gesture); it shows state + live logs and redirects to the preview URL when state = running. Failed -> show the error and logs there.
4. The adapter kills devserve up after 180 s (previews/devserve.ex:66); a first ReportSystem compile takes longer. Return as soon as the tmux window is up (state starting) and let reconcile move it to running, or use the app's timeout.
5. Show the preview in the PR row too (Start / Open / Stop), not only in the ticket drawer.

Acceptance: from the PR page, click Preview on a ReportSystem PR with no session -> a new tab shows Starting with logs -> it lands on the app when it listens; Stop removes the tmux window and the preview DB; a second PR runs at the same time on another port. Tests at the worktree-resolution and redirect seams.
