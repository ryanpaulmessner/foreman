---
id: fm-9mm
title: "Sessions: live tree and session detail pages, with links that work"
type: epic
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:map"]
created: 2026-11-01
closed: null
close_reason: null
---

## Destination

An approved spec (`tight-spec` format) and design pack (`design-pack`) for **Sessions**: a board page with the live tree of agent sessions (main coordinator → epic coordinators → their builds), each one marked **working**, **in review** or **waiting on you**, and a **session detail** page (live view, and a "dead" view with Resume after it ends). Every session link on a card, ticket or epic opens the detail page, and session controls (launch an epic coordinator, focus, message, continue, park, resume, stop) live there. Building starts after approval, through `to-tickets`.

## Notes

- Chartered with Ryan, 2026-11-01. Background: asklog Chief comparison, `~/dev/work/research/asklog-chief/analysis.md` (gap 1).
- **Why:** session links on question cards are in an error state about 90% of the time. A diagnosis on 2026-11-01 (251 decision cards, 14 days) found ~72% were broken when the card was created: 82 cards had no session, 40 builds stored their coordinator's name instead of their own, 59 coordinators were never registered and their names differ from their tmux windows. A detail page alone fixes only the ended / closed-window cases. **Session identity must be fixed first.**
- **Settled at charting (Ryan):**
  - The tree shows board-known sessions only: coordinators and their builds nested under them. Unknown tmux panes are not shown.
  - The board launches coordinators (including epic coordinators, absorbing fm-3c3.8). Builds are started by coordinators, not by the board.
  - Controls: Launch epic coordinator, Focus terminal (also a small icon on cards), Send message, Continue, Park / Relaunch, Resume, Stop (with a confirm; the worktree is kept), Note to all coordinators.
  - Every source link goes to `/sessions/:id`. When the pane is gone, the page shows the **dead view** from history ("Session ended at …"), never an error box. Detail pages never expire; the list hides ended sessions after 7 days.
  - Resume from the dead view: coordinators continue their Claude conversation; Pi builds resume if Pi can, otherwise "Relaunch build on this ticket" through the coordinator.
  - Detail page includes a **read-only** snapshot of recent pane output (read half of fm-zgd.10).
  - Desktop only (1440 and an 820 window).
  - This map absorbs fm-knr (card source + jump), fm-zgd.10 (read-only half), fm-3c3.8 (epic coordinator launch) and fm-3c3.9 (pane-mode Continue). Re-scope or close them when the spec is ticketed.
- **Skills every session uses:** `grilling`, `domain-modeling`. Design tickets also run `statechart`, `information-architecture`, `ux-laws`, `ux-critique`, `ui-patterns` (empty, loading, error, success states), and build variants from the real board CSS and markup (no generic look). Design artifacts are published as Artifacts and linked from the ticket.
- Ticket text follows ASD-STE100 (simple technical English).
- 2026-11-03 user: 2026-11-03: fm-9mm.7 closed - detail page is option B with A's round grouping; Continue stays on at a usage limit and the page needs a 'continue on another model' fallback (Ryan). Buttons size to their labels (Ryan saw label overflow in A's rail).
- 2026-11-03 claude: 2026-11-03: Ryan: move Relaunch and Start fresh off the Initiatives strip to the main coordinator's detail page (card 06a13e91). Question cards spec approved (card 63a4319f).

## Decisions so far

- [Can a Pi build session be resumed in its worktree after its pane closes?](tickets/fm-9mm.2.md): yes, with `pi --session-id <uuid>` recorded at launch; Resume shows only when the id, worktree and session file exist, else Relaunch build.
- [How to show recent pane output read-only on the detail page](tickets/fm-9mm.3.md): poll `capture-pane -e` every 1 s, 200 lines, only for a viewed pane; own ANSI-to-HTML converter; save the last capture on exit, Stop and Park for the dead view.
- [Session identity: how every ask, build and coordinator records its own name and parent](tickets/fm-9mm.1.md): new `agent_sessions` table (name, kind, parent, pane id, conversation id) written by every launcher; asks fixed to a session when accepted, by name then pane; no backfill. Data view in `docs/specs/sessions-view.design.md`.
- [UX audit of the current board before the new pages are designed](tickets/fm-9mm.4.md): Go to session must become a link with state shown before the click; one source row per card; one shared state-colour function; tree reuses the PR stack pattern. Findings in `docs/specs/sessions-view-audit/ux-audit.md`.
- [Session lifecycle statechart: states, events and the three user-facing labels](tickets/fm-9mm.5.md): model-checked state table and controls; an open card always means waiting on you; builds outlive their coordinator and Relaunch resumes it first; undeliverable answers go to the coordinator. [Report](https://claude.ai/artifact/7Wqutsha9uYNtkox2JSaK3).

## Not yet specified

- How the Sessions page relates to Needs you and the Initiatives page in the nav (one place for "waiting on you", or both).
- Notifications when a session changes state (OS notification exists for requests; is a state change worth one?).
- History retention and how much of the timeline the dead view keeps (events only, or transcript excerpts).

## Out of scope

- Phone width and working from the phone (Ryan's "dogwalk" idea): a separate effort later.
- Starting Pi builds directly from the board.
- Typing into a pane from the browser (the interactive half of fm-zgd.10).
- Showing tmux panes the board does not know about.
- Several machines in one tree.
