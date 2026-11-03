# UX audit of the current board (fm-9mm.4)

Date: 2026-11-02. Board: the live board at http://127.0.0.1:4747, read-only. Widths: 1440x900 and 820x1180.
Method: skills `ux-critique` (heuristic evaluation, visual hierarchy, information density, affordance, colour), `ux-laws` and `ui-patterns` (ux-writing, loading, error, feedback). The screenshots are in this folder and are named `<page>-<width>.png`. A name with `-top-` is the first viewport only. A file without `-top-` is the full page.

Limits of this audit:

- Read-only. I did not click "Go to session", Focus, Relaunch or any answer button. Thus I did not see the "Cannot focus the session. Copy this command" box live. The text about that box and the "Source unknown" and "This session has ended" states comes from the code (file:line given). At the time of the audit, all 5 pending cards had a known, live source.
- The brand lens (`critique-brand-consistency`) is not used. The repo has no `mood.md`, `voice.md` or `tokens.md`.
- The chrome-devtools MCP browser was in use by a different session. I used Playwright (from `~/dev/work/tools/e2e`) in a new headless browser. I did not get console errors or page errors on any page.

Severity scale (Nielsen): 1 cosmetic, 2 minor, 3 major, 4 must fix before release.

---

## (a) Findings that the Sessions pages must FIX

### A1. The session link is an action button that fails after the click (severity 4)

- **Heuristic:** 1 Visibility of system status; 5 Error prevention; 9 Error recovery.
- **What:** "Go to session" is a `<button phx-click>`. It shows the same way for a live pane, a closed window and a pane with no attached terminal. The user learns that the link is broken only after the click. Then the card gets a status line ("The session window is closed.") or a tmux command to copy. The map says that about 90% of these clicks fail.
- **Where:** `lib/foreman_web/components/request_context.ex:54-64` (button), `:72-79` (window closed), `:80-105` (copy box). Screenshot: `needs-you-push-card-1440.png`.
- **Fix:** Every source becomes a real link (`<.link navigate={~p"/sessions/#{id}"}>`). The detail page always opens: live view or dead view, never an error. Show the session state on the card **before** the click (a small state badge next to the name, see B3). Keep the terminal focus as a second, small icon button (charter: "Focus terminal, also a small icon on cards"). Disable that icon, with a reason in its title, when the pane is gone.

### A2. The card names the asking session in three places, in two different orders (severity 3)

- **Heuristic:** 4 Consistency; law: proximity, similarity.
- **What:** A card shows the session three times:
  1. "Source: main · claude · foreman · fm-cxv.4" (session, harness, repo, ticket), 12px grey text (`request_context.ex:47-53`).
  2. The header strip "Push · fm-cxv.4 · P2 · claude · main" (harness, session), 160px lower, in a different block (`needs_you_live.ex:970`, `:1054`).
  3. The "Go to session" button under the source line.
  The two strings put "claude" and "main" in opposite orders. "main" can also be read as a git branch name. The session name is not a link.
- **Fix:** Show the session one time, in the card header row, as one unit: state badge + session name as a link + kind ("coordinator" or "build"), for example `● waiting on you  support-board-coord  coordinator`. Remove the separate "Source:" line and the actor/session text in the header. Keep repo and ticket in the existing ticket link chip.

### A3. "Source unknown" puts the work on the user (severity 3)

- **Heuristic:** 9 Error recovery; 2 Match with the real world; law: Tesler.
- **What:** When the board does not know the source, the card shows "Source unknown · <session> · <repo> · <ticket> · <actor>". If a session name exists, a box shows at page load: "Cannot focus the session. Copy this command to your terminal." and a raw tmux command. The user did not try to focus anything, so the message is not true at that time. The "Ask about this" panel shows "Source unknown. Copy the question to the agent's chat." plus a code block to copy by hand.
- **Where:** `request_context.ex:50-52`, `:80-105` (the box shows when `!@source`); `card_conversation.ex:134-158` (lines 119-158 of the file).
- **Fix:** Identity is now recorded at ask time (fm-9mm.1), so "unknown" becomes rare. For old cards, write what the board knows in plain words: "The board does not know which session asked this." Do not show a tmux command at load time. Give one recovery action ("Find the session" opens the Sessions tree, filtered to the repo and ticket).

### A4. "This session has ended." is a dead end (severity 3)

- **Heuristic:** 9 Error recovery; 1 Visibility of system status; law: Zeigarnik, peak-end.
- **What:** The text has no time, no history link, and no next step. The Go to session button is removed.
- **Where:** `request_context.ex:65-71`.
- **Fix:** The text links to the dead view: "Session ended 2 h ago · Open" (shared time format, full time on hover). The dead view gives Resume or "Relaunch build on this ticket" (fm-9mm.2).

### A5. There are five different "copy this command" patterns (severity 3)

- **Heuristic:** 4 Consistency; feedback pattern (no confirmation).
- **What:**
  1. A code block + "Copy command" button (`request_context.ex:92-104`).
  2. A read-only input + "Copy" button (`planning_session.ex:93-115`).
  3. A code block, no button (`needs_you_live.ex:921-937`, the card notice "No terminal is attached… Attach with:").
  4. A code block, no button (`card_conversation.ex:147-158`).
  5. Flash text "No terminal is attached. Run: …" (`planning_session.ex:15-20`, `initiatives_live.ex:86`).
  No copy button shows "Copied". The clipboard error is ignored (`request_context.ex:132`, `.catch(() => {})`).
- **Fix:** The Sessions pages use one component for the attach command: read-only mono field + "Copy" button that changes to "Copied" for 2 s and selects the text if the clipboard fails. Show it only on the detail page, in a "Terminal" section, not on cards.

### A6. The coordinator controls offer actions that cannot work, with equal weight (severity 3)

- **Heuristic:** 1 Visibility of system status; 5 Error prevention; affordance (CTA clarity); law: Hick.
- **What:** On Initiatives the strip shows "Coordinator ended". Focus, Relaunch and Start fresh all show as enabled (the live DOM had `disabled=false` on all three). Focus is enabled because the check uses only `window` (`initiatives_live.ex:377`), and an ended session keeps its window name. Focus and Start fresh are ghost buttons and Relaunch is outline, so no button is primary. When the state is "ended", Relaunch is the only useful action. The state is a raw lowercase atom in grey (`initiatives_live.ex:367-369`). All three buttons have `cursor: default`.
- **Note:** `/settings` has no session controls and no session list (`settings-1440.png`). The coordinator strip on Initiatives, the per-ticket Launch/Focus/Relaunch button (`planning_session.ex:38-75`) and the ticket Sessions tab (A8) are the only session views today.
- **Where:** `initiatives_live.ex:362-410`. Screenshots: `coordinator-controls-1440.png`, `initiatives-top-1440.png`.
- **Fix:** Controls on the detail page come from the session statechart (fm-9mm.5). Show only the actions that the current state allows. Make the one next action primary (ended → Resume; waiting on you → open the card). Disabled actions show the reason as text, not only a title tooltip. The state is a badge with a label (B3), not a raw atom.

### A7. Raw machine states show as user text (severity 2)

- **Heuristic:** 2 Match with the real world.
- **What:** `ended`, `running`, `in_progress`, `spec_approved`, `committed`, `bd: open`, "Allowed next events: progress commit abandon". The planning-session status prints `{@session.state}` (`planning_session.ex:89`). The Recent outcomes badges print the state with only `_` replaced (`request_card.ex:13`).
- **Fix:** Sessions use the three user-facing labels from the map (working, in review, waiting on you) plus "ended". Map each internal state to a label in one function. Never render an atom.

### A8. The ticket panel "Sessions" tab is a raw field dump (severity 2)

- **Heuristic:** 8 Minimalist design; 6 Recognition over recall.
- **What:** Each session is a box with the window name, "Started / Last seen / Ended" (all "2 d ago"), then every detail key sorted A-Z: base SHA, brief path, harness, model, report path, session, window, workdir. There is no state, no link and no action. The tab row is cut off at 1440 in the side panel ("R…" for Requests).
- **Where:** `ticket_detail.ex:464-485`, tabs at `:320-330`. Screenshot: `card-detail-sessions-tab-1440.png`.
- **Fix:** Change the tab to a short list of session rows (B4): state badge, name as a link to `/sessions/:id`, kind, "last seen" time. Move the full fields to the detail page, in a "Details" disclosure.

### A9. A card is about 800px tall, so one card fills the screen (severity 2)

- **Heuristic:** 8 Minimalist design; information density; law: Miller, serial position.
- **What:** The push card is 798px tall at 1440. The full Needs you page is 8104px for 5 cards. The question or action is below the Kind / Part of / From block, the Source line, the Go to session button and Withdraw. "Wrong question" and "Ask about this" are outside the card border (`needs_you_live.ex:561`, and the conversation component), so they look like they belong to the next card.
- **Where:** Screenshots `needs-you-1440.png`, `needs-you-top-1440.png`, `needs-you-decision-card-1440.png`.
- **Fix (for the session parts):** The session row in the card header (A2) replaces three rows. The Sessions tree must not repeat full cards. A "waiting on you" session row links to its card; it does not embed it.

### A10. At 820 the side panel covers the whole page (severity 2)

- **Heuristic:** 3 User control and freedom; law: figure-ground.
- **What:** Under `lg` (1024px), the ticket panel is `fixed inset-0`. It hides the sidebar and the card. The only exit is the X at the top right.
- **Where:** `needs_you_live.ex:430`. Screenshot: `card-detail-820.png`.
- **Fix:** `/sessions/:id` is a full page with the normal sidebar, not a panel. On the tree page at 820, open the detail by navigation, not by an overlay.

### A11. The board does not show when the live connection is lost (severity 3 for a live page)

- **Heuristic:** 1 Visibility of system status; loading-states.
- **What:** The flash group shows only `:info` and `:error` (`layouts.ex:180-195`). There is no "reconnecting" state. The top bar shows only on page navigation (`assets/js/app.js:49-51`). A live tree and a pane snapshot that refresh every second will look current when they are stale.
- **Fix:** The Sessions pages show "Last updated <time>" near the tree and the pane snapshot, and a clear "Not connected. Trying again…" line when the socket is down (`phx-disconnected` class on the container).

---

## (b) Patterns the Sessions pages must STAY CONSISTENT with

### B1. Shell and navigation

- Use `<Layouts.app active={:sessions} …>` (`layouts.ex:15`). Nav items use `bb-nav` and `bb-nav-active`, with `aria-current="page"`, and a `hero-*` icon at `size-4`.
- Recommended place for "Sessions": the second item, after "Needs you" and before "Answers" (serial position: the two live "act now" places stay first). Use the icon `hero-rectangle-stack` or `hero-command-line`. Do not add a second count badge next to it: the Needs you badge already counts what waits on you. If a count is needed, count only "working" sessions, in plain grey text, not in a badge.
- Pass `repos` to the layout. Today the "Projects · tickets" section shows on Initiatives, Settings and epic pages, but not on Needs you or Answers (`layouts.ex:107`). Use the same choice on both Sessions pages so the sidebar does not move.
- Page header: `<h1 class="text-xl font-semibold">` + optional `Badge.badge` count, as on Needs you (`needs_you_live.ex:351-354`). Initiatives uses `text-[22px]`: do not copy that one.
- Breadcrumb for the detail page: the same style as the epic page ("Initiatives / foreman / fm-cxv", mono for ids). Use "Sessions / <coordinator> / <build>".

### B2. Surfaces, tokens and type

- Card or panel: `rounded-xl border border-base bg-base p-5 shadow-sm` (Needs you cards) or `.bb-panel` (`assets/css/app.css:16`). Lists and tables: `.bb-initiative-panel`, `.bb-section-title`, `.bb-section-label`, `.bb-initiative-row` (`app.css:31-36`).
- Colour tokens: `--border-base` / `border-base`, `bg-sunken` (secondary surface and code blocks), `text-foreground-softer` (labels, meta), `--primary`. Do not add hex colours. The `bb-hist-*` and `bb-project-dot` hex values are already outside the tokens.
- Section labels: `.bb-label` (11px, uppercase, 600).
- Ids, SHAs, branches and paths: `font-mono`. Times: `ForemanWeb.TicketDetail.timestamp` (shared human format, full time on hover).
- Secondary buttons: `rounded-md border border-base px-3 py-2 text-sm hover:bg-sunken`, or the Fluxon `Button.button` variants. The one primary action is the filled dark button (as Approve and Answer).

### B3. State colours (Fluxon `Badge.badge` colours)

Today's mapping (`initiatives_live.ex:313-321`):

| Colour | Meaning today |
|---|---|
| `info` (blue) | building, dispatched |
| `warning` (amber) | speccing, spec_approved, reported, in_review; also `stale`, P1 |
| `success` (green) | committed, pr_open, merged, shipping, shipped |
| `danger` (red) | P0, refused history events |
| neutral | queued, ticketed, done (on Initiatives), kind chips |

Use this for the new labels:

| Session label | Colour | Reason |
|---|---|---|
| working | `info` | same as building / dispatched |
| in review | `warning` | same as reported / in_review |
| waiting on you | `primary` + `hero-inbox` icon | the Needs you icon; amber is already used for 3 meanings (review, stale, P1) |
| ended | neutral | history, no action needed |

- Always put text in the badge, not only a dot (colour is never the only cue).
- Put the label-to-colour map in **one** shared function. Today there are three different maps: `initiatives_live.ex:313`, `epic_live.ex:335` (no entry for shipping or speccing, and done is green), and a fixed `info` in `ticket_detail.ex:251` and `epic_live.ex:119`. Thus "committed" is green on the epic page and blue in the ticket panel, and "shipping" is green on Initiatives and blue in the epic header. Do not add a fourth map.

### B4. Tree and row patterns to reuse

- **Reuse: the PR stack tree** (`pull_requests_live.ex:440-460`). Each level indents 28px (`min(depth, 5) * 28`), with an elbow connector (`rounded-bl-lg border-b-2 border-l-2 border-base`). Each row is a bordered card with a title, mono chips and a status on the right, plus "Waiting on #451". This is the closest match for coordinator → epic coordinator → build. Screenshot: `pull-requests-top-1440.png`.
- **Reuse: the Initiatives grouped panel** for list sections ("Working", "Ended in the last 7 days"): `.bb-section-title` with a count, collapsible rows with a chevron, `.bb-section-label` sub-groups ("In flight", "Never started", indented by depth, `initiatives_live.ex:822`).
- **Reuse: "Synced 1 min ago" + Refresh** at the top right of the PR page (`pull_requests_live.ex:374`, `:402-407`) for "last updated".
- **Avoid: the epic "Blocking graph"** (`epic_live.ex:249-260`). With no edges it is one long column of cards in a wide grey box (`epic-fm-cxv-1440.png`). A session tree has a real parent, so draw it as an indented list, not as a graph.
- **Avoid: two status chips for one item** (stage + ticket status, for example "queued" + "in_progress" on the epic page, `epic-fm-9mm-1440.png`). A session row has one state badge.

### B5. Empty, loading and error states (keep the style, fix the words)

- Empty list: a dashed box, centred grey text (`needs_you_live.ex:356-361`, "No pending requests"). Keep the style. Write words that say what will appear and what to do, for example "No sessions are running. Launch a coordinator from Initiatives." Do not use "No items" (`needs_you_live.ex:381-386`).
- Busy buttons: `phx-disable-with="Relaunch…"` and similar (`planning_session.ex:69`). Use the same for Resume, Stop and Send message.
- Destructive actions: `data-confirm` with a question (`initiatives_live.ex:404`, "Start a new coordinator conversation?"). Stop needs this, and says that the worktree is kept.
- Not found: "Epic not found" with the breadcrumb only (`epic-missing-1440.png`). Charter: a session detail page never says "not found" for a known id. It shows the dead view.

---

## (c) General board issues found along the way (outside this map)

1. **Answers: the filter inputs are not visible** (severity 3). The labels "Search", "Repo" and "Ticket" show, but the input boxes have no border or fill (`answers_live.ex:91-93`, `answers-top-1440.png`). The "Show archived" checkbox has no gap after it. The page also uses a centred column, while the other pages are left-aligned.
2. **Info and error flashes look the same** (severity 2). Both use `bb-panel` with no colour or icon (`layouts.ex:185-191`).
3. **"Always" checkbox has no gap** between the box and the label on decision cards (`needs_you_live.ex:1133`, `needs-you-decision-card-1440.png`). Severity 1.
4. **Push card shows an empty row** "Expected remote commit" when there is no value (`request_card.ex:296`). Hide the row when the value is empty. Severity 1.
5. **Epic header shows `bd: open`**, a word from the old beads system (`epic_live.ex:121`). The epic stage history shows "backfill — → ticketed" while the stage chip says "shipping" or "building". Severity 2.
6. **Epic columns repeat "PLANNED"** under every column, also when the column is empty (`epic-fm-cxv-1440.png`). Severity 1.
7. **Ticket card stage is wrong for in-progress work on the epic page**: fm-9mm.4 and fm-9mm.5 are in the "Queued" column with the chip "queued" next to "in_progress" (`epic-fm-9mm-1440.png`). Severity 2.
8. **Card kind words "Internal" and "Unsorted"** do not tell the user anything about the decision. Severity 1.
9. **Needs you: "Wrong question" and "Ask about this" sit outside the card border** (`needs_you_live.ex:561`), so they look like part of the next card (law: common region). Severity 2.
10. **The request drawer repeats the full cards** at 640px wide (`request_drawer.ex:111`). On `/needs-you` it shows the same cards as the page under it. Severity 1.
11. **Buttons have `cursor: default`** (Fluxon buttons on Initiatives). Severity 1.
12. **Long ids and paths break in the middle at 820** (for example `feat/card-l|ifecycle` in the push card, `needs-you-push-card-820.png`), because of `break-all`. Use `overflow-wrap:anywhere` with `<wbr>` after `/`. Severity 1.

---

## Screenshot index

| Page | 1440 | 820 |
|---|---|---|
| Needs you, full | `needs-you-1440.png` | `needs-you-820.png` |
| Needs you, first view | `needs-you-top-1440.png` | `needs-you-top-820.png` |
| Push card | `needs-you-push-card-1440.png` | `needs-you-push-card-820.png` |
| Decision card | `needs-you-decision-card-1440.png` | `needs-you-decision-card-820.png` |
| Waiting on you without a card | `needs-you-waiting-1440.png` | |
| Recent outcomes (open) | `needs-you-recent-1440.png` | |
| Request drawer | `request-drawer-1440.png`, `request-drawer-on-initiatives-1440.png` | `request-drawer-820.png`, `request-drawer-on-initiatives-820.png` |
| Card detail panel | `card-detail-1440.png` | `card-detail-820.png` |
| Card detail, Sessions tab | `card-detail-sessions-tab-1440.png` | `card-detail-sessions-tab-820.png` |
| Initiatives | `initiatives-1440.png`, `initiatives-top-1440.png` | `initiatives-820.png`, `initiatives-top-820.png` |
| Coordinator controls | `coordinator-controls-1440.png` | `coordinator-controls-820.png` |
| Epic page | `epic-fm-cxv-1440.png`, `epic-fm-9mm-1440.png`, `epic-fm-9mm-top-1440.png` | `epic-fm-cxv-820.png`, `epic-fm-9mm-820.png`, `epic-fm-9mm-top-820.png` |
| Epic not found | `epic-missing-1440.png` | `epic-missing-820.png` |
| Pull requests | `pull-requests-1440.png`, `pull-requests-top-1440.png` | `pull-requests-820.png`, `pull-requests-top-820.png` |
| Answers | `answers-1440.png`, `answers-top-1440.png` | `answers-820.png`, `answers-top-820.png` |
| Settings | `settings-1440.png` | `settings-820.png` |
| Previews | `previews-1440.png`, `previews-top-1440.png` | `previews-820.png`, `previews-top-820.png` |
| This week | `week-1440.png` | `week-820.png` |
| Documents | `documents-1440.png` | `documents-820.png` |

Not seen live (read from code only): the copy-command box after a failed Focus, "Source unknown", "This session has ended", "The session window is closed", the Session waiting card, the drawer error state, and the loading state of a slow page.
