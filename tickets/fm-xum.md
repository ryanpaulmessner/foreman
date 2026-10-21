---
id: fm-xum
title: "This week: a plain-words view of recent ReportSystem work and the weekly report"
type: epic
status: closed
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:map"]
created: 2026-10-21
closed: 2026-10-21
close_reason: "superseded: spec published as fm-49x"
kind: internal
---

## Destination

An approved spec for a foreman page 'This week' (/week, left menu under Initiatives) with the weekly report for Arnoldo built in, sliced into Pi-sized builds. Ryan-only.

## Notes

- Agreed in the charting interview 2026-10-21 (Ryan):
  - ReportSystem (work repo) tickets only.
  - Workweek is Mon 00:00 to Sun 23:59 US Central.
  - Worked = any board event in the week.
  - Carried over = tickets with activity last week that are not done, plus anything shipped after the last sent report, with a weeks-carried count.
- Layout: grouped by kind (Feature by epic, Break-fix, Mapping, Access). Five plain stages per kind: Building, Waiting on you, Waiting on others, On staging, Shipped.
- Shipped means in prod: a merged staging to production PR that contains the ticket's PR. Merged to staging only is On staging.
- Each item shows a plain title and expands to detail with links (PR, spec, prompt, reviews, ticket).
- The agent writes a ## Summary in the ticket at build start, PR open and close. The page shows only stored text, with no AI call at view time. Backfill summaries for activity since Mon 2026-10-13.
- Report:
  - 'Draft weekly report' assembles the email from the summaries.
  - Subject 'Ryan weekly update - MM/DD'.
  - Section 'Key Accomplishments & Current Focus'.
  - Section 'Upcoming Milestones': waiting items, top ready tickets per epic, and epics due soon (needs an epic target date).
  - The text is editable and saved per week.
  - 'Mark as sent' stamps the items; finished and reported items drop off. Never sends.
  - First week: everything finished by end of day Fri 2026-10-17 counts as reported.
- Skills: grilling and domain-modeling for decisions, prototype for layout, writing-for-people with ASD-STE100 plain English for all copy. Never run mix in ~/dev/foreman (live board).
- 2026-10-21 user: 2026-10-21: superseded by the tight-spec docs/specs/this-week.md, published as epic fm-49x (children fm-49x.1-.6), plus sk-jy8, work-l90, work-pgj.

## Decisions so far

## Not yet specified

- How the coordinator skills (slice-loop, dispatch, foreman close-out) are changed so the three summary writes happen without Ryan asking. This depends on the summary format.
- Whether 'Waiting on you' should link straight to the Needs you card for that item.

## Out of scope

- Support Board (T-###) requests handled without a build. Reading the prod tickets schema is a separate decision.
- The foreman, skills and dotfiles repos.
- AI-written prose in the report.
