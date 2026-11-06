---
id: fm-qpm.1
title: "foreman doc path: print the layout path for a ticket document or a note"
type: feature
status: in_progress
priority: 2
parent: fm-qpm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-06
closed: null
close_reason: null
---

## What to build
The layout rules as one module (decisions 1, 2, 3) and a CLI command that uses them (decision 4).
- `foreman doc path <kind> <ticket-id> [--next]` prints the absolute path in the main checkout of the ticket's repo: kinds brief, message, report, review, loop, pr, plan, evidence. Rounds: round 1 has no suffix, later rounds add -rN; `--next` gives the next free round.
- `foreman doc path note <kind> <slug>` prints `notes/<today>-<kind>-<slug>.md` in the current repo's main checkout. Kinds: research, diagnostic, audit, update, message, check, decision, retro. Slug: lowercase kebab-case, at most 40 characters.
- The repo comes from the ticket prefix (registered repos), so the command works from a worktree, another repo, or a ReportSystem checkout for a work- ticket.

## Interfaces
Produces a layout rules module (classify a repo-relative path as allowed, legacy or refused, with the suggested `doc path` command). Ticket 2 consumes it.

## Acceptance
- [ ] `foreman doc path report fm-x` prints `<main checkout>/builds/fm-x/report.md` from a worktree, from another repo, and from a ReportSystem checkout for a work- ticket.
- [ ] `--next` returns brief-r3.md when brief.md and brief-r2.md exist.
- [ ] `foreman doc path note diagnostic zoho-timestamps` prints today's note path; an unknown kind or bad slug fails and lists the allowed kinds.
- [ ] Unit tests on the rules module cover every fixed name, round suffixes, and refused names.

Spec: docs/specs/doc-layout.md (Decisions). Design pack: docs/specs/doc-layout.design.md.
