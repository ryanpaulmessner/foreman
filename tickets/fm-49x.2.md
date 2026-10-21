---
id: fm-49x.2
title: "PR history and Shipped / On staging from git containment"
type: feature
status: in_progress
priority: 2
parent: fm-49x
blocked_by: ["fm-49x.1"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: null
close_reason: null
---

## What to build
Shipped and On staging stages from real git containment. Spec decisions 8 (Shipped, On staging rows), 9, 10. Riskiest ticket: start it right after the first.
- New table of ticket–PR links (repo, ticket id, PR number, URL, base branch, head SHA, state, first and last seen). The forge sync writes it from now on with the existing link rule.
- Background job every 10 minutes: read merged PRs from GitHub for the last 21 days; `git fetch origin production staging` in the work repo's `code_path` (read-only toward the remote; never changes local branches or the working tree); `git merge-base --is-ancestor <head> origin/<branch>` per linked PR; cache results so they survive a page reload.
- One-time backfill from the last 60 days of merged PRs.
- Page rules: Shipped only when all merged PRs of the ticket are in production; On staging when merged and in staging but not production; details show "not found in staging" when a merged head is in neither.
- The page makes no network or git call; it reads the table and the cache only.

## Interfaces
Produces PR link rows and containment results (per PR: in_production, in_staging, checked_at) that the page model consumes.

## Acceptance
- [ ] Acceptance check 2: for each item shown Shipped, `git merge-base --is-ancestor <head> origin/production` exits 0; a PR merged to staging after the last staging → production PR shows On staging.
- [ ] Containment function tested against a temporary git repo with a merge commit on staging and on production, plus a squash-merged PR (shows "not found in staging").
- [ ] A ticket with two merged PRs, one in production and one not, is not Shipped.
- [ ] Fetch failure (no network): the job logs one warning, keeps the last cached results, and the page still renders.
- [ ] Backfill run once is idempotent (second run adds nothing).

## Notes
- 2026-10-21 user: 2026-10-21 Ryan: 'I can't really tell where any given item is in its process; is it in PR, merged to staging, in prod? … worked today/yesterday/Monday?' Added to this slice: a per-row progress strip (Building -> PR open -> On staging -> In production, or Done / Closed, not done) and the last-activity day on the row (Today / Yesterday / weekday).
