---
id: fm-qpm.2
title: "foreman check refuses new documents outside the layout"
type: feature
status: open
priority: 2
parent: fm-qpm
blocked_by: ["fm-qpm.1"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-06
closed: null
close_reason: null
---

## What to build
Decision 5: `foreman check` (already run by the pre-commit hook) checks .md and .html files added in the commit being made.
- Always allowed: README.md, AGENTS.md, CLAUDE.md, CHANGELOG.md anywhere, plus `[docs] allow` globs in foreman.toml.
- `[docs] legacy` folders: edits to existing files pass, new files are refused.
- Each error names the file and prints the `foreman doc path` command that gives the right path.
- Decision 8: `foreman adopt` adds `builds/*/evidence/` to .gitignore.
The hook itself does not change (ask-first boundary). Installing the rebuilt CLI goes through a chore card.

## Interfaces
Consumes the layout rules module from fm-qpm.1. Adds `[docs] allow` and `[docs] legacy` to foreman.toml config.

## Acceptance
- [ ] In a test repo with `slices/` listed as legacy: adding slices/new-thing.md fails and names the right command; editing an existing slices/*.md passes.
- [ ] Adding builds/work-abc/notes.md fails; adding builds/work-abc/report-r2.md passes.
- [ ] README/AGENTS/CLAUDE/CHANGELOG pass anywhere; an allow glob passes.
- [ ] Ticket validation output is unchanged for repos with no added documents.

Spec: docs/specs/doc-layout.md (Decisions). Design pack: docs/specs/doc-layout.design.md.
