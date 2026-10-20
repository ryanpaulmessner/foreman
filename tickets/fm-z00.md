---
id: fm-z00
title: "Intake: Work Board requests and staging failures become work- tickets with evidence"
type: feature
status: open
priority: 2
parent: null
blocked_by: []
related: ["fm-wcp"]
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: null
close_reason: null
---

## Context
Proposal 15 rev 2, E3 (`~/dev/work/proposals/15-local-software-factory.md`): a triage step reads incoming work, reproduces it read-only and records evidence, and does not start fixes (a buffer the coordinator groups before any slice). Pieces now exist:
- Work Board Intake tickets: read-only SELECTs on prod `tickets.tickets` (`~/dev/work/CLAUDE.md`).
- Staging failures and freshness: `~/dev/work/tools/staging/bin/rs failures|freshness|last-runs` (SQL, read-only; skill `staging-ops`).
- Reproduction: `~/dev/work/tools/verify/bin/verify ui|metric`.
- Destination: `work-` foreman tickets in `~/dev/work/tickets/`.

## What to build
A coordinator routine (schedule TBD) that creates or updates one `work-` ticket per new Work Board request or new staging failure, with the evidence attached and the T-### carried, and groups related items before anyone builds.

## Decisions needed (Ryan)
Which sources first; how often; whether it may create tickets itself or only propose them for approval.
