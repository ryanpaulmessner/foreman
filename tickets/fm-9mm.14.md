---
id: fm-9mm.14
title: "Session page: live controls (Focus, Send message, Continue, Park, Stop)"
type: task
status: open
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.13"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: null
close_reason: null
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 17-18 and R11, for live sessions; absorbs fm-3c3.9.
- Controls from the Decision 17 table: Answer on the card, Continue, Focus terminal, Send message (one-line box, Decision 18), Park (coordinators only, never main, never shown on builds), Stop (in-page confirm, focus on "Keep it running"), Try again now. Off controls go in the one "Not available now:" line with their reasons. Result and failure lines with the exact copy.
- Park and Stop save the capture, then close only the session's own pane, never its window (R11).
- Continue sends exactly `continue` and Enter to that pane, including pane-mode builds.
- Buttons size to their labels: no fixed widths, no wrap or overflow at 1440 or 820 (Ryan).

## Interfaces
- Consumes the machine events (stop, park, continue) and the capture save call.

## Acceptance
- [ ] Stop on a scratch build: last output saved, only that pane closes, worktree and branch exist after, dead view offers Resume or Relaunch build (spec acceptance 6).
- [ ] Park on a scratch epic coordinator with one pane build in its window: the coordinator's pane closes and the build pane keeps running (spec acceptance 7).
- [ ] Continue on a pane-mode build at a usage limit sends only `continue` and Enter to that pane, never the coordinator pane (spec acceptance 8).
- [ ] No control label wraps or overflows at 1440 or 820 (verify ui of every control state; spec acceptance 14).
- [ ] tmux integration tests on a temporary socket for Focus, Continue, Send message, close-one-pane.
