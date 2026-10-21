---
id: fm-9xi
title: "Needs you cards explain themselves: what, part of, from, why now"
type: feature
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: null
close_reason: null
kind: internal
---

Ryan, 2026-10-21: 'these questions coming through seem very dense and context dependent and I often have zero clue what they're even related to; like are they one-off fixes, are they part of a feature, are they from requests in asana/support board/things I've filed as one-offs; I feel like I'm always coming back here to play catch up.'

The card should carry context from the ticket itself, so a terse question from any agent still makes sense. Related: fm-knr (source build + jump to session), fm-5fq (answers page), fm-49x.3 (## Summary).

## Acceptance
- [ ] Every card shows a header built from board data, before the question: ticket title (plain Summary title when present), kind (Feature/Break-fix/Mapping/Access/Internal), 'Part of' = parent epic title or 'one-off', 'From' = the origin the ticket records (Asana link, Support Board T-###, or the ticket's first line when neither), and the ticket's 'What users see' summary line when present.
- [ ] Each option shows its consequence text when the asker gives one (new optional --option-detail on foreman ask decision); the CLI refuses a decision whose question is shorter than a minimal length and has no --context.
- [ ] Cards for the same ticket group under one heading; a card whose ticket is closed or whose question was answered elsewhere can be withdrawn (fm-qxp).
- [ ] Screenshot of three real cards (a one-off, a feature ticket, a Support Board request) in light and dark.
