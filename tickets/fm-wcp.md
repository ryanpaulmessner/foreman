---
id: fm-wcp
title: "Tracker repo separate from code repo: work-* tickets driving ReportSystem worktrees and PRs"
type: feature
status: open
priority: 2
parent: null
blocked_by: []
related: ["fm-96o"]
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: null
close_reason: null
---

## What to build
User request 2026-10-19. Let a tracker repo's tickets drive work whose code, worktrees and PRs live in a different git repo.

On the work Mac, tickets live in `~/dev/work` (project `work`, prefix `work`): a local-only workspace repo with no remote, so `forge = "none"`. The code is `~/dev/work/ReportSystem`, a separate git repo nested inside it and gitignored by it, the team's repo on GitHub (`AGarcia-IHS/ReportSystem`, deploy branch `staging`). Build worktrees are ReportSystem worktrees under `~/dev/work/fix-branches/` (67 today). ReportSystem must not be adopted: `tickets/`, an `AGENTS.md` block or `core.hooksPath` in the team's checkout are not allowed.

Foreman assumes one repo per project for all of this:
- push requests require the worktree to belong to the configured repo (same git common dir);
- open_pr and merge use the project's `github` remote and forge snapshot;
- CR panels, stage links (`cr_opened`/`cr_merged`) and previews key off the same project.

Add a way for a project to name its code repo or repos (path, GitHub remote, base branch), so that:
- push and open_pr for a `work-*` ticket validate against the ReportSystem checkout and its worktrees, and target ReportSystem on GitHub;
- the forge sync reads ReportSystem's PRs and links them to `work-*` tickets (by branch, PR title or body reference; PR titles there also carry Work Board `T-###` numbers, which are not foreman ids);
- nothing is written into the code repo except through the existing push/PR requests.

Interacts with fm-96o: ReportSystem PRs are exactly the human-merge case (team merges on GitHub, base `staging`).

## Acceptance
- [ ] Config can attach a code repo (path, github, base branch) to a tracker project; validation in Settings
- [ ] A push request from a ReportSystem worktree for a `work-*` ticket passes the worktree guard; a worktree of an unrelated repo is refused
- [ ] open_pr for that ticket opens against the code repo's GitHub remote and base branch (scratch repo)
- [ ] The CR panel shows the code repo's PRs on the tracker project, linked to tickets
- [ ] Nothing is added to the code repo's working tree, hooks or config
- [ ] Projects without a code repo behave exactly as before
