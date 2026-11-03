---
id: fm-9mm.4
title: "UX audit of the current board before the new pages are designed"
type: decision
status: closed
priority: 2
parent: fm-9mm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:task"]
created: 2026-11-01
closed: 2026-11-02
close_reason: "Audit done: 5 must-fix findings for session links, consistency rules for the new pages, 12 board issues outside the map"
---

## Question

AFK. Run `ux-critique`, `ux-laws` and `ui-patterns` over the board pages as they are now at 1440 and 820: Needs you (cards, source line, Go to session, copy-command box), the request drawer, Initiatives, the epic page, PR panel, Settings session controls (Focus, Relaunch, Start fresh). Take screenshots from a worktree preview (`PREVIEW=1`) or the running board, read-only. Record findings that the Sessions pages must fix or must stay consistent with (nav, card patterns, state colours, empty and error states). Link the findings file and screenshots from the ticket.

## Notes
- 2026-11-02 user: Resolved 2026-11-02 (AFK task, ux-critique + ux-laws + ui-patterns over the live board at 1440 and 820, read-only, Playwright headless; no console errors). Findings: docs/specs/sessions-view-audit/ux-audit.md, 50 screenshots in the same folder (not committed). Must fix: (1) Go to session is a button that fails only after the click (request_context.ex:54-105) -> link to /sessions/:id with state shown before the click; (2) the asking session shows three times per card, two in opposite order (request_context.ex:49, needs_you_live.ex:970) -> one header row: state badge + name link; (3) Source unknown shows 'Cannot focus' and a raw tmux command on load; 'This session has ended.' has no time or next step; (4) five copy-command patterns, none says Copied; (5) Initiatives coordinator says ended but Focus stays clickable (initiatives_live.ex:377), raw state word, no primary button, no signal when the live connection drops. Consistency: Layouts.app, bb-nav, hero icons, Sessions second in nav with no second count; working=info, in review=warning, waiting on you=primary + hero-inbox, ended=neutral, from one shared function (three pages use three colour maps today); tree from the PR stack pattern (28px indent + elbow, pull_requests_live.ex:440-460), not the epic blocking graph; tokens border-base, bg-sunken, text-foreground-softer, .bb-panel, .bb-label, .bb-section-title, TicketDetail.timestamp, font-mono ids; dashed empty box with useful copy, phx-disable-with on busy buttons, data-confirm for Stop. Section (c): 12 board issues outside this map (worst: Answers filter boxes cannot be seen). Note: Focus/Relaunch/Start fresh live on Initiatives (/), not /settings.
