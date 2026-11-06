---
id: fm-qpm.4
title: "Move foreman's own briefs, reports and drafts into builds/ and notes/"
type: task
status: open
priority: 2
parent: fm-qpm
blocked_by: ["fm-qpm.2"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-06
closed: null
close_reason: null
---

## What to build
Decision 7 for this repo.
- Tracked docs/briefs/ (36) and docs/sessions/ (36) move with git mv to builds/<id>/brief.md and report.md (rounds as -rN).
- Untracked drafts/briefs, drafts/sessions, drafts/pr-bodies move to brief*, report*, review*, pr.md and evidence/.
- Names that do not map to a ticket id go to notes/ or onto a list for Ryan.
- README and docs links are updated. Board database rows keep old paths.
- drafts/ is shared with other running coordinators: check that no session is writing there before moving, and move only files whose ticket is closed or whose session has ended; list the rest.

## Acceptance
- [ ] docs/briefs/, docs/sessions/ and drafts/ are gone or hold only the listed in-use files.
- [ ] README and docs links resolve.
- [ ] `foreman check` passes on the whole tree.

Spec: docs/specs/doc-layout.md (Decisions). Design pack: docs/specs/doc-layout.design.md.
