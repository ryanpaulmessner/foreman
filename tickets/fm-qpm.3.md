---
id: fm-qpm.3
title: "Skills write documents through foreman doc path"
type: task
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
Decision 9 and the skills half of decision 4.
- The foreman skill gets a Documents section: the layout table, the fixed names, `foreman doc path`, and the commit check.
- pi-window: with no --report, the default is `foreman doc path report <first ticket>` (today it is drafts/sessions/<name>.md).
- dispatch, slice-loop, pr, research, tight-spec, design-pack, to-tickets, wayfinder, handoff and code-review name no path of their own and point to the Documents section. Builder briefs say to write the report to the absolute path given.
- The AGENTS.md block that `foreman adopt` writes gets one pointer line.
Skills live in ~/dev/utils/skills/skills/ (verify and staging-ops come from work/ihs-skills; leave those unless they name doc paths).

## Acceptance
- [ ] grep over the listed skills finds no hard-coded drafts/, slices/, docs/briefs or docs/sessions paths.
- [ ] pi-window with no --report records the doc path report path on dispatch.
- [ ] A new `foreman adopt` AGENTS block contains the pointer line.

Spec: docs/specs/doc-layout.md (Decisions). Design pack: docs/specs/doc-layout.design.md.
