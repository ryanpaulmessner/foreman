---
id: fm-fdw
title: "Waiting without a card: split by who acts, a working button per row, design pass"
type: feature
status: closed
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["ux"]
created: 2026-11-02
closed: 2026-11-03
close_reason: "PR #6 merged (b8508fb), deployed 2026-11-03: merge list on Needs you, coordinator close-out notes (close_out_nags), list fixes, Recent outcomes stays open. Tests 986/26 env-only failures vs base 27."
---

Ryan 2026-11-02: the 'Waiting on you without a card' section on Needs you does not work and has no design.

## Problem
- Each item is a link that only opens the ticket panel. 'Request a push' and 'Review the report' have no matching action there; the only button in the panel is the preview Start, so it looks like the buttons do nothing.
- 14 of 18 live items are agent close-out work (reports to review, push cards to post), not Ryan's. 4 are PRs he merges on GitHub.
- No design pass: tall bordered boxes, no grouping, counts, age or owner.

## Decision (Ryan, 2026-11-03, card 8239f6af)
**The board nags the coordinators.** Stuck agent work leaves Needs you. Needs you shows only things Ryan does.

## What to build
1. **Needs you section "Pull requests for you to merge"** (replaces 'Waiting on you without a card'). One line per PR: repo · PR number · title · ticket · age (shared human time format) · **Open on GitHub** button (opens the PR URL in a new tab). Count in the section title. Hidden when empty. Decisions with no card (a decision ticket that blocks work but has no pending card) stay in this section as their own rows with the action that works for them, or move to the nag list if the owner is an agent: decide in the build and say which in the report.
2. **Nag**: when an item of agent work (report not reviewed: stage `reported`; committed with no push card in a push repo: stage `committed`) has no pending card for 30 min, the board sends the owning coordinator a note through `Foreman.CoordinatorNote` naming the ticket, what is missing and the next command. It sends again every 3 hours while the item stays stuck, and stops when the item's stage or cards change. The nag schedule is a declared `Foreman.Fsm` machine (house rule), not ad hoc fields.
   - Owner: the coordinator that dispatched the ticket (from dispatch history). If the board cannot find it, or the note is not delivered (pane busy, ended or gone), record that; do not fall back to Ryan's Needs you.
   - Stuck items show on the owner's session page when fm-9mm builds it; until then the nag history is visible on the ticket's history.
3. **List logic fixes** from the 2026-11-02 sweep: match open PRs by head branch as well as ticket links (work-p8x.31 has PR #463); parked tickets are never listed (work-8ec.22.1); shipped tickets left in_progress are not stuck work.

## Acceptance
- [ ] Needs you lists only PRs for Ryan to merge (plus decisions with no card, if kept), each with a working Open on GitHub button. No row links to a place without its action.
- [ ] A stuck item older than 30 min sends one note to its owning coordinator; again after 3 h; stops when it changes. Tests drive the Fsm with an injected clock.
- [ ] Undeliverable or ownerless nags are recorded with the reason.
- [ ] PR matched by head branch; parked tickets excluded.
- [ ] verify ui screenshots of Needs you at 1440 and 820, light and dark, before and after, on the push card.

## Notes
- 2026-11-02 user: Sweep 2026-11-02 found the list logic is also wrong, not only the design: (1) 7 foreman items were shipped tickets left in_progress (now closed); (2) work-hlf shipped in PR #368; (3) work-p8x.31 shows 'push not requested' but its branch has open PR #463, so it belongs in the merge list; match open PRs by head branch, not only by ticket links; (4) work-8ec.22.1 is parked on purpose; parked tickets must not be listed. Old mockup (two groups, superseded by the decision): https://claude.ai/artifact/2ZQ8pQ2v471ppUz4zE1uFm
- Code today: `lib/foreman/waiting_without_card.ex` (list), `lib/foreman_web/live/needs_you_live.ex` (section), `Foreman.CoordinatorNote` (note delivery).
