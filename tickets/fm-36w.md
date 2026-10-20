---
id: fm-36w
title: "Work Board (T-###) timeline shows foreman build stages"
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
The ReportSystem Work Board (in-app tickets, live on prod; team board `/work`, cards `T-###`) was designed as "a substrate for agent sessions": its `tickets.events` kinds already include `agent_post` and `overlap_found` (branch `feat/work-board-pointing`, `lib/report_system/tickets/event.ex`). Work from a T-### ticket carries the number in slice prompts, branches and PR titles (`~/dev/work/CLAUDE.md`, 2026-10-14). The foreman board now owns the build stages (dispatch → progress → report → review → commit → PR).

## Idea
Post foreman stage changes for a work ticket that names a T-### as `agent_post` events on that Work Board card (claim, plan with declared files, one line per round, PR link), so requesters and the team see progress without Asana or chat.

## Blocked on a decision (Ryan + Arnoldo)
Tickets live in prod (staging loses them nightly), so this is a prod write. Proposal 15 rev 2 (E5, `~/dev/work/proposals/15-local-software-factory.md`) proposed a keyed, off-by-default endpoint through the `Tickets` context instead of per-developer DB roles; proposal 16 chose direct DB access first. Also decide: does foreman write, or does the app pull from foreman.
