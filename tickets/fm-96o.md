---
id: fm-96o
title: "Human-merge policy: every change goes through a GitHub PR that a person merges"
type: feature
status: closed
priority: 2
parent: null
blocked_by: []
related: ["fm-zgd","fm-zgd.6"]
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: 2026-10-19
close_reason: "Merged into main 1bc449d (skills 8136134); work repo configured: github AGarcia-IHS/ReportSystem, human merge, base staging; PR page lists 18 PRs, no merge control."
---

## What to build
User request 2026-10-19. On the personal machine, slices end at a local commit or local merge (`forge = "none"`), or the board merges a PR after confirmation (`forge = "github"`). On the work machine (IHS ReportSystem and other work repos) this is not permitted. Every change must reach a shared branch through a GitHub PR, and a person merges it on GitHub. For now, foreman and agents never merge in these repos.

Add a per-repo merge policy to `foreman.toml`: the current behaviour (board merges after confirmation, the default) and a new human-merge policy. Let a top-level value set the default for all repos on a machine, so the work machine sets it once. Key names are the builder's choice.

Under human merge:
- **PRs only.** Close-out ends at `push` then `open_pr`. No local merge of a worktree branch into another local branch. No push to the base branch or the default branch, also for one-off tickets. This overrides the default-branch exception in fm-zgd Decision 6 for these repos.
- **No merges by foreman.** `ask merge` is refused at creation with a clear reason, and the merge job also refuses (enforce it in the job, not only in the UI). The CR panel shows no merge action. It shows the PR link and "Waiting for a person to merge on GitHub".
- **Observe the merge.** Forge sync moves the linked ticket from `pr_open` to `merged` when GitHub reports the PR merged, for every merge method (merge commit, squash, rebase). The team can squash on GitHub, so do not assume a merge-commit sha.
- **Base branch from config.** The PR base is a per-repo setting, not the forge default branch. ReportSystem deploys from `staging`, and `main` is old and not in use. Push and PR guards use this base wherever they now use "default branch".
- **Stacks.** Foreman does not retarget child PRs after a person merges the parent. It shows the manual step, as it does when the forge has no retarget capability.
- **Requires GitHub.** Human merge with `forge = "none"` is a config load error: Settings shows the error and the last good config stays in force.

Update the house skills to match: `foreman` (request table and close-out), `dispatch` close-out step 6 (end at `open_pr` done, report the PR URL, keep the ticket open until the merge is observed), and `finishing-a-development-branch` (no "merge locally" option in a human-merge repo). Never use `git merge`, `gh pr merge` or a direct push as a fallback.

## Acceptance
- [ ] Config: the policy key validates per repo and at top level; human merge with `forge = "none"` shows an error in Settings and the old config stays in force
- [ ] `foreman ask merge` in a human-merge repo is refused at creation with a named reason; a merge job for that repo refuses before any forge write
- [ ] The CR panel for a human-merge repo has no merge control and shows the PR link and the waiting-for-a-person state
- [ ] A push to the base branch or default branch is refused at creation and in the job for a human-merge repo, also for an Unplanned ticket
- [ ] `open_pr` uses the configured base branch (scratch repo with a non-default base such as `staging`)
- [ ] In the scratch forge repo, a PR merged by a person on GitHub, once with a merge commit and once squashed, moves its ticket to `merged` on the next sync and shows the close suggestion
- [ ] Repos on the default policy, and `forge = "none"` repos, behave exactly as before; existing merge tests pass unchanged
- [ ] `foreman`, `dispatch` and `finishing-a-development-branch` skills describe the human-merge close-out; `scripts/check.py` passes in the skills repo
- [ ] mix precommit green

## Ask-first boundaries
- Any push, PR or merge on a real work repo during the build (use the scratch forge repo).
- Changing the default policy for repos already configured on the personal machine.
