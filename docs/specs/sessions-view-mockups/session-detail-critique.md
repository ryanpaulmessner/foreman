# Session detail page: variants and critique (fm-9mm.7)

Date: 2026-11-02. Mockup: `session-detail.html` in this folder (one file, the board's compiled CSS inlined, light and dark by the board tokens). Screenshots: `sd-<variant>-<state>-<width>.png` in this folder. The `A-*`, `B-*`, `C-*` files without `sd-` belong to the Sessions tree ticket (fm-9mm.6), not to this page.

Method: skills `ux-critique` (visual hierarchy, information density, affordance, colour, heuristic evaluation), `ux-laws` and `ui-patterns`, on Playwright screenshots at 1440 and 820. I fixed what the mockup can fix one time, then took the screenshots again.

## What the mockup shows

- **Real board parts.** Layout shell, `bb-nav`, Fluxon badges and buttons, card classes and tokens are copied from the live board markup (`/needs-you`, `/epics/foreman/fm-9mm`). Layout helpers that the compiled CSS does not have use the `sd-` prefix and board tokens only. They become Tailwind classes in code.
- **Real data** from `foreman_dev` (read-only): the Pi build `marketing-mappings-04` (work-bih.3, Marketing Mappings slice 4) under the epic coordinator `maestro`. It shows its real stage events, review rounds, reports, its real question card (`0ebc66f8`, "Should Zoho location mapping keys keep leading and trailing spaces?"), its push and open-PR cards and commit `5a28124`. The usage-limit state uses `maestro` itself, because only Claude sessions report a usage limit today (`session_hooks.ex`). One progress note is an example and is marked "(example)": this build wrote none.
- **Recent output** uses the real colour codes from a live Pi pane (`%631`) and a live Claude pane (`%615`), read with `capture-pane` only. The text is written for this build. The Claude usage-limit line is an example of the wording.
- **Switcher:** variant (A, B, C, card source row), 9 states, width 1440 or 820, theme, scale. Stop opens an in-page confirm. Each control shows its busy text and its result message. Copy changes to "Copied" for 2 s.

## The three variants

### A. Workbench (two columns, controls rail)

Output and a timeline grouped by review round on the left. A sticky rail on the right: the next step, every control with the reason it is on or off, the attach command and details.

Strengths:
- Every control is always in the same place, with its reason as text next to it. A user learns the page one time (spatial consistency).
- Timeline grouped by review round matches how builds work (report, review, changes asked). Old rounds fold.
- Output and the next step are both above the fold at 1440.

Findings fixed:
- Two filled primary buttons (the next-step panel and the controls list showed the same action). Now only the panel has the filled button (Von Restorff: one item stands out).
- Park showed on builds with "Only coordinators park". Removed: a control that never applies to this kind of session is noise (Hick).
- "Live · updated 1 s ago" showed twice (section header and terminal head). Now only in the terminal head.
- At 820 the rail fell under the output and the timeline, so the next step was about 1000 px down. The rail now comes first under 1100 px.

Findings left open:
- Seven control rows, four of them off in most states (severity 2, Hick). The fixed positions are the point of A, so I did not cut them.
- At 820 the page is long: rail, then output, then timeline (severity 2).

### B. Next step first (one column, tabs) — recommended

One column at the Needs-you width (`max-w-3xl`). The ticket title is the heading, the state badge and session name under it. Then the next-step panel with the one primary action, then only the controls that work now, and one line that names the others and why they are off. Recent output, Timeline and Details are tabs.

Strengths:
- One clear entry point and one filled button per state (visual hierarchy: pass).
- Fewest choices on screen: 2 or 3 buttons (Hick). Stop sits apart, at the right end (Fitts; destructive action separated).
- Same width and card style as Needs you, so the two pages feel like one product (Jakob).
- Works the same at 820; nothing moves to a second column.

Findings fixed:
- The live state opened on the Timeline tab, so the "is it alive" signal (output) was hidden. Now the first tab is **Recent output** when the session is live and nothing waits on you, and **Timeline** when it waits on you or ended.
- At 820 "Live · updated 1 s ago" wrapped alone onto its own line at the right. It is now the last item of the meta row.
- The R9 alternative text in the panel read like product copy. It is now a dashed "Mockup note".

Findings left open:
- Output is one click away when a session waits on you (severity 1). The card is the right first step there.
- The off-controls line is long in the dead states at 820 (5 items, severity 1). It could fold into "Not available now (5)".

### C. Console (terminal first)

Toolbar over a tall output panel, timeline and details under it. The next-step panel shows only when you must act or the session ended.

Strengths:
- Best for watching a build work: the output is the largest thing on the page.
- Tooltips plus one text line explain disabled buttons.

Findings fixed:
- Same duplicate primary as A (panel and toolbar). The toolbar now leaves out any action that is in the panel.

Findings left open:
- For working and in review there is no "what now" text, only the output (severity 2, visibility of system status). A reader must read terminal text to know the state.
- The dead timeline is one long flat list (about 20 rows); A's round grouping would fix it (severity 2).
- The page is a terminal viewer more than a status page; the map says typing into panes is out of scope, so the big panel promises more than it gives (severity 1).

### Card source row (Needs you), before and after

`sd-card-source-row-1440.png`, `-820.png`.

- **Before:** the session shows 3 times (Source line, Go to session button, "pi · marketing-mappings-04" in the strip). The button fails after the click when the pane is gone.
- **After:** one line under the strip: "Asked by **marketing-mappings-04** · build under maestro · ● live" plus a small focus icon. The name is a link to `/sessions/:id`. Ended: "ended 3 min ago · answer goes to maestro", focus icon off with the reason "The pane is closed". Unknown (old cards): "The board does not know which session asked this. Find the session".
- **Change from the audit (A1):** the audit asked for a state badge on the card. By R2 a session with an open card is always "waiting on you", so the badge would say the same thing on every card. The row shows **live or ended** instead, which is the fact the user needs before the click.

## Cross-cutting findings (all variants)

| # | Finding | Lens | Sev | Status |
|---|---|---|---|---|
| 1 | Error state (tmux down) keeps the blue "working" badge from 18:09; it can look current | Heuristic 1 | 2 | Open. Sub-line says "Not checked since 18:09"; the badge could fade or add "?" |
| 2 | Continue is on before the usage limit resets; pressing it early stops again | Tesler, error prevention | 2 | Open, needs a decision (below) |
| 3 | Output panel is always dark, also in the light theme | Colour, consistency | 1 | Kept on purpose: the agent colours are made for a dark terminal and fail contrast on `bg-sunken` |
| 4 | Timeline dots use 10 px icons that are hard to read | Typography | 1 | Open; colour and title carry the meaning |
| 5 | Open-card dot is solid `--primary`, which is black in light mode, so it reads as "important" but not as "waiting" | Colour | 1 | Open; the "open" badge with the inbox icon sits under it |

Laws that changed the design: **Hick** (B shows only working controls; A drops Park on builds), **Von Restorff** (one filled button per page), **Fitts** (Stop apart from constructive actions; card focus icon is 26 px, over the 24 px pointer minimum), **Tesler** (Relaunch resumes the dead coordinator by itself, R8; the user does not do it), **Zeigarnik** (the dead view names where it stopped: "Ended 18:16 during round 3 fixes"), **peak-end** (every action ends in a result line that says what happened and what comes next), **serial position** (Sessions is second in the nav, after Needs you).

## Recommendation: B, with the round grouping from A

B gives one clear next step per state, the fewest choices, and the same column and card style as Needs you. That is the page most people open from a card, so it should look like the card's home. Take two things from A into B: the timeline grouped by review round (old rounds folded), and the reason text for each off control (B shows it in one line). Keep C's idea only as the "Recent output" tab, made tall.

## Copy for each state (recommended variant)

Label = state badge. Sub = text next to the badge. Panel = next-step panel title and body.

| State | Label | Sub | Panel |
|---|---|---|---|
| Live, working | working (info) | Round 2 · output 2 s ago | **Working on round 2 fixes.** Nothing waits on you. The page updates when the build reports, asks or stops. |
| Waiting on you, question | waiting on you (primary, inbox icon) | Question since 17:50 | **It asked you a question.** *<question>* Asked at 17:50. The build waits until you answer. [Answer on the card] |
| Waiting on you, usage limit | waiting on you | Usage limit · resets 7pm | **Stopped at the Anthropic usage limit.** The limit resets at 7pm (in 13 min). Continue before then stops again. [Continue] |
| In review | in review (warning) | Round 2 report · maestro reviews | **maestro reviews round 2.** The build is idle and waits for the review. Nothing waits on you. |
| Ended, can resume | ended (neutral) | Ended Oct 30, 15:13 · the pane closed | **Ended Oct 30, 15:13 (18 h ago).** The pane closed. Its work is committed (5a28124, PR #471). You can resume the same Pi conversation in its worktree. [Resume] |
| Ended, cannot resume | ended | Ended 18:16 · cannot resume | **Ended 18:16 during round 3 fixes (15 min ago).** This build cannot resume: the board has no Pi session id for it. Relaunch starts a new build on work-bih.3 in the same worktree, through its coordinator. [Relaunch build on this ticket] |
| … and its coordinator ended (R8) | ended | same | Extra line: "maestro ended at 18:20 too. Relaunch resumes maestro first, then sends it the note." |
| Ended with an open card, cannot resume (R2, R9) | waiting on you | Session ended 17:55 · cannot resume | **Its question is still open.** *<question>* The session ended at 17:55 and cannot resume. When you answer, the board sends your answer and the question to maestro as a note, and the card closes. [Answer on the card] [Relaunch build on this ticket] |
| Ended with an open card, can resume | waiting on you | Session ended 17:55 · can resume | Same title. Body: "When you answer, the board resumes the session first, then gives it your answer." |
| Parked coordinator | parked (neutral) | Parked 14:02 · idle for 30 min | **Parked at 14:02.** The board closed the pane after 30 min with no output. Its builds keep running. [Relaunch] |
| Dead coordinator, cannot resume (R4) | ended | Ended 14:02 · cannot resume | **Ended 14:02.** The board has no conversation id for it. Start fresh opens a new conversation for this epic. [Start fresh] |
| Loading | (from the server render, no wait) | as above | Output panel: skeleton lines and "Reading the terminal…". Live line: "Connecting…". Nothing else waits: the header, controls and timeline come with the first render. |
| Error: tmux does not answer | last label, faded | Not checked since 18:09 | **The board cannot reach tmux.** tmux does not answer, so the board cannot read or control this pane. The session may still run. The board tries again every 5 s. The label and output below are from 18:09. [Try again now] Output panel head: "Cannot read the terminal: tmux does not answer. Trying again in 5 s." Focus, Send message, Continue, Park and Stop are off with the reason "tmux does not answer." |
| Error: connection lost (A11) | last label | — | Live line: "Not connected. Trying again…". Output panel dims. |
| Empty: no timeline events | — | — | "No events yet. Progress notes, reports, questions and stage changes show here." |
| Empty: no output yet (live) | — | — | Output panel: "No output yet. The agent has not printed anything." |
| Empty: no saved output (dead) | — | — | Output panel: "No output was saved for this session. It ended before the board saved pane output." |
| Saved output head (dead) | — | — | "Saved Oct 30, 15:13, when the pane closed" / "Saved 18:16 from the last check (no exit capture)" / "Saved when you pressed Stop". |

Time format: the shared `TicketDetail.timestamp` (relative, full time on hover). A detail page for a known id never says "not found"; it shows the dead view.

## Controls: when on, confirm, busy text, result

Off reasons show as text, never only as a tooltip. Busy text uses `phx-disable-with`.

| Control | On when | Off reason (examples) | Confirm | Busy | Result message |
|---|---|---|---|---|---|
| Answer on the card | an open card | "No card is open." | none | — | Goes to the card on Needs you. |
| Continue | waiting, usage limit | "Only after a usage limit." | none | Continuing… | "Sent “continue” to maestro. The label changes to working when output starts." |
| Resume | ended or parked, and resume id (+ for Pi: worktree and session file) exist | "No Pi session id was recorded at launch." / "The worktree was removed." / "The session is live." | none | Resuming… | "Resumed marketing-mappings-04 in ~/dev/work/fix-branches/feat-marketing-mappings-04. Output shows here in a few seconds." |
| Relaunch build on this ticket | ended build without Resume | "The session is live." | none | Relaunching… | "Sent maestro the note: “Relaunch the build for work-bih.3 on feat/marketing-mappings-04.” The new build shows under maestro when it starts." With R8: "Resumed maestro and sent it the note: …" |
| Start fresh | dead coordinator without Resume (R4) | — | in-page: "Start a new conversation for maestro? The old conversation stays in history." [Start fresh] [Cancel] | Starting… | "Started a new maestro conversation. Its builds stay under it." |
| Focus terminal | live, tmux answers | "The pane is closed." / "tmux does not answer." | none | Focusing… | "Brought marketing-mappings-04 to the front in your terminal." If no terminal is attached: "No terminal is attached. Copy the attach command from Details." |
| Send message | idle, or waiting on a question | "The agent is working. A message now interrupts it. Wait for it to stop, or Stop it." / "A message does not help at the usage limit. Use Continue." | none | Sending… | "Sent to marketing-mappings-04." |
| Park | live coordinator, not main | "Only coordinators park." / "The main coordinator does not park." | none | Parking… | "Parked maestro. The last output is saved. Relaunch is on this page. Its builds keep running." |
| Stop | every live state | "The session already ended." / "tmux does not answer." | in-page panel, no browser dialog: **Stop marketing-mappings-04?** "The agent stops now and loses what it has not saved. The worktree feat-marketing-mappings-04 and the branch feat/marketing-mappings-04 stay. You can resume it or relaunch it from this page." (coordinator: "Its builds keep running.") [Stop session] [Keep it running]; focus goes to "Keep it running" | Stopping… | "Stopped marketing-mappings-04 at 18:14. The last output is saved. The worktree and branch stay. Resume or Relaunch is on this page." |
| Copy (attach command) | live | "The pane is closed. Nothing to attach to." | none | — | Button says "Copied" for 2 s. If the clipboard fails, the text is selected. |
| Try again now (tmux error) | tmux error | — | none | Trying… | Fail: "tmux still does not answer. Check that the tmux server default runs. The board tries again every 5 s." Success: the error panel goes away. |

Failure results (all controls): "Could not <verb> marketing-mappings-04: <reason in words>. Nothing changed." The message stays until the next action. Success messages stay until the state changes.

## Open questions for Ryan

1. **Variant:** B with A's round grouping (recommended), or A, or C?
2. **Continue before the limit resets:** keep it on (spec today), turn it off with a countdown until the reset time, or let the board press Continue at the reset time by itself?
3. **Card source row:** show live / ended (recommended, because by R2 an open card always means "waiting on you"), instead of the state badge the audit asked for?
4. **Page heading:** the ticket title (B) or the session name (A, C)? Cards and the tree use the session name; the title is easier to recognise.
