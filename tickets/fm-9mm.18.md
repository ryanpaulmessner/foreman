---
id: fm-9mm.18
title: "One-click Launch coordinator on epics"
type: task
status: closed
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.12","fm-9mm.9"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-05
close_reason: "PR #18 merged (42ef2dc); skills template in skills PR #2; deployed 2026-11-05, epic page shows the controls"
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 28-31 (step 4); absorbs fm-3c3.8 and fm-9mm.8.
- "Launch coordinator" on the epic row (Initiatives) and the epic page for epics in idea, draft, ticketed, building or shipping; none for done or abandoned. Today's `launchable?` allows only idea and draft.
- One click: Claude, the main coordinator row's model (`--model`, no flag when null), the repo's main checkout, a fresh conversation. No form.
- Starts a window named by the epic id in the project's session on `tmux -L foreman`; `agent_sessions` row kind `epic_coordinator`, parent = the live main coordinator (else the most recent; else none, under Unassigned); `FOREMAN_SESSION` = its name.
- Idea and draft keep the `/tight-spec` prompt. Ticketed and later epics get a new `epic-coordinator` template in the foreman skill's session-launch templates: orient on the epic, dispatch its frontier in pane mode, close out under the usual rules, touch no other epic.
- Control by state: none -> Launch coordinator (Launching…); live -> Focus; parked or ended -> Resume and the name link.

## Acceptance
- [ ] On a ticketed scratch epic with a stub `claude` that prints argv and prompt: one window named by the epic id on `-L foreman`, the epic-coordinator prompt and the main coordinator's model; a second click focuses it; done and abandoned epics show no control (spec acceptance 12).
- [ ] Row written with the right kind and parent (context test).
- [ ] verify ui of the epic row and epic page controls at 1440 and 820, light and dark.
