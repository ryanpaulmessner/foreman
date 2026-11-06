---
id: fm-qpm.5
title: "Freeze the work repo's old document folders and index them"
type: task
status: open
priority: 2
parent: fm-qpm
blocked_by: ["fm-qpm.2","fm-qpm.3"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-06
closed: null
close_reason: null
---

## What to build
Decision 6 for ~/dev/work.
- foreman.toml lists slices/, epics/, drafts/, proposals/, research/, smells/, specs/, docs/ (raw data) and the loose notes/* files as `[docs] legacy`. epics/*/AGENTS.md and slices/_builder-rules.md stay live (allow globs).
- `foreman doc index` writes docs/legacy-index.csv once: path, guessed kind, guessed ticket, date, confidence. Ticket from **Ticket:**/**Foreman:** lines and work-xxx ids in the text; kind from the name patterns in the survey.
- Work AGENTS.md, slice-loop and _builder-rules point to the Documents section.
Nothing is renamed or moved (ask-first boundary).

## Acceptance
- [ ] docs/legacy-index.csv exists; at least 80% of slices/*/reports/* rows have a guessed ticket.
- [ ] A new file in slices/ is refused on commit in work; an edit passes.

Spec: docs/specs/doc-layout.md (Decisions). Design pack: docs/specs/doc-layout.design.md.
