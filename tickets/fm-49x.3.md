---
id: fm-49x.3
title: "Plain-English summaries on the This week page"
type: feature
status: open
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
Plain-English summaries on `/week`. Spec decisions 11–13.
- The ticket projection extracts `## Summary` (like `## Notes` and `## Acceptance`) and removes it from `description`. Fields: `Title:`, `What users see:`, `How it works:`, `Open or risky:`, `Report line:`; any may be missing.
- A `Title:` line replaces the ticket title on this page only.
- Expanded details show the summary fields, then links: each PR known so far, the epic spec (`spec_link`), the ticket file, and any Markdown paths named in the ticket body that exist on disk (shown as document links like Needs you cards).
- A ticket with no `## Summary` shows "no summary yet".

## Interfaces
Consumes the page model from the first ticket. Produces a `summary` field on the ticket projection (map of the five fields) that the weekly report ticket reads for `Report line`.

## Acceptance
- [ ] Acceptance check 6: a ticket with `## Summary` shows its fields; its `description` has no Summary heading; a ticket without one shows "no summary yet".
- [ ] Projection tests: all fields, some fields, no section, a `Title:` override, a Summary between Notes and Acceptance.
- [ ] A body path that does not exist on disk is not linked.
- [ ] Light and dark screenshots with one item expanded.
