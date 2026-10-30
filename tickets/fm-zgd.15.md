---
id: fm-zgd.15
title: "Projects whose tickets and code live in different repos (work tickets in ~/dev/work, code in ReportSystem)"
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
close_reason: "Merged into main aa3d3e0; work repo has code_path = ~/dev/work/ReportSystem."
---

2026-10-19: foreman ask push for work-8ec.10 was refused with foreign_worktree: the work project's path is the workspace repo ~/dev/work (tickets/), but ReportSystem is a separate, gitignored nested repo with its own remote (AGarcia-IHS/ReportSystem), and builds run in its worktrees under ~/dev/work/fix-branches. So the board can list ReportSystem PRs (fm-96o) but cannot push or open PRs for them, and every ReportSystem push is still a manual command.

Add a per-repo code checkout: e.g. code_path = "~/dev/work/ReportSystem" next to path (tickets). Push/open_pr/branch snapshots and the worktree check use code_path (worktrees of that repo are accepted); tickets keep using path. Keep human-merge rules (merge_base staging, no merge). Config validation: code_path must be a git checkout whose origin matches github. Tests + mix precommit.
