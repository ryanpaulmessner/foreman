# Question cards and Answers page: options and critique (fm-zgd.17)

Date: 2026-11-03. Mockup: `question-cards.html` in this folder. It is one file with the board's compiled CSS inlined (`GET /assets/css/app.css`, 2026-11-03), and it shows light and dark by the board tokens. It has a switcher for option, page, state, width, theme and scale. Screenshots are in this folder and are named `<option>-<page>-<state>[-dark]-<width>.png`. They show the first view only: 1440x900 and 820x1180.

Method: skills `ux-critique` (visual hierarchy, information density, affordance, colour, heuristic evaluation), `ux-laws` and `ui-patterns`, on Playwright screenshots. I made one fix pass and then took the screenshots again.

## What the mockup shows

- **Real board parts.** The layout shell, `bb-nav`, Fluxon badges and buttons, the ticket chip, `fm-markdown` and `bb-filter-control` / `bb-switch` come from the live `/needs-you`, `/answers` and `/settings` markup. New classes use the `bb-` prefix and board tokens only (`--border-base`, `--background-sunken`, `--foreground-softer`, `--primary`, `--success(-soft)`, `--danger(-soft)`). In code they go into `app.css` next to `.bb-panel`. A Playwright check found that all 279 classes the mockup renders exist in the inlined CSS. Mockup chrome uses `mk-*`.
- **Real data** from `foreman_dev` (read-only), at board time Nov 3, 10:27:
  - Pending at 10:24: `f438c994` and `4e77750e` (fm-9mm.7, from `foreman-board`, with long agent text and a recommendation).
  - Older real cards, shown as pending so that each source case shows: `2675f631` (work-tl7.8, maestro, the longest option details), `8c0cad00` (chore, merge PR #492), `1ebb4ce4` (push, with a long worktree path), `c47f5c7c` (from the ended Pi build `sb-notify-nobody-told`, ended Oct 30) and `32d662ff` (fm-9mm.5, `chief-research`, which has no session row, so the source is unknown).
  - Answers: the 4 rows in `answer_versions`. The standing-answers table is empty, so the mockup shows its empty line.
  - "Your answers" (option C): the 6 newest answered decision cards, with Ryan's real note on one of them.
- **Example data, not real:** the question typed in the "Copied" state; the parent `support-board-coord` for `sb-notify-nobody-told` (taken from its epic, work-8ec; its session row has no parent); and the database-timeout reason in the error states.
- **Not in the mockup:** "Waiting on you without a card". It waits on the fm-fdw pick. The mockup leaves it out so that the card list can be judged alone.

## Shared to all three options

These fix the ticket findings whatever option is picked:

- **One source row (A2).** It uses the session-detail mockup pattern: "Asked by **name** · role · ● live" plus a focus icon. The ended variant is "Asked by **name** · build · ○ ended 4 d ago · answer goes to support-board-coord", with the focus icon off and the title "The pane is closed". The unknown variant is "The board does not know which session asked this. Find the session". The name is a link to `/sessions/:id` (A1), so no click fails. The variants contain no tmux command (A3), and the ended variant gives the time and the next step (A4).
- **No board context block.** Kind / Part of / From from the ticket go away. The kind words "Internal" and "Unsorted" go away with them ((c)8). The agent's own **What** and **Why now** lines show as a tight definition list. The board parses them from the card text. Part of, From, Details and the free agent notes fold behind "More context: Part of, From, agent notes". Today the card shows Part of and From twice, one time from the board and one time in the agent's prose.
- **One region.** Note, Answer, Decline, Always, Ask about this, Wrong question and Withdraw are all inside the card border, in one sunken footer strip ((c)9, law of common region). Ask about this, Wrong question and Withdraw open small panels in that strip.
- **"Always use this answer"** has an 8 px gap between the box and the label ((c)3). The longer label says what the box does.
- **Status lines differ by kind ((c)2).** Success: green-soft fill, check icon. Error: red-soft fill, warning icon, plus a Try again button. Info: sunken fill, info icon. Colour is never the only cue.
- **One copy pattern (A5):** a read-only mono field plus a Copy button that changes to "Copied" with a check icon for 2 s. It selects the text if the clipboard fails. On cards it shows only when the board cannot send ("Ask about this" from an unknown source). The attach command moves to the session page, as the session-detail spec says.
- **Long ids and paths ((c)12)** use `overflow-wrap:anywhere` with `<wbr>` after `/` (see the push card worktree), not `break-all`.
- **Ticket panel under lg (A10):** a right sheet, `min(460px, 100% - 96px)` wide, over a scrim. The sidebar and the left edge of the list stay in view. Esc, the X and a click on the scrim close it. At 1440 it stays in the right column, as today.
- **Request drawer ((c)10):** one row per card (kind, source, age, question, Open). It shows no full cards.
- **Answers ((c)1):** the page is left-aligned with the other pages. Search, Repo and Ticket use `bb-filter-control` (border, fill, 36 px). Search has an icon. Show archived is the `bb-switch` from Settings, with an 8 px gap. The meaningless actor word "user" is gone.

## The three options

### A. Compact card

One card per request, as today, in the Needs-you column (768 px). The header is one line: kind, ticket chip (the ticket title is in its tooltip), priority, time and the source row. Under it come the question, What and Why now (2 lines each), "More context", the options as tight rows, and the footer strip. An option's detail shows 2 lines and opens in full when you pick or focus that option. Answers: one filter row, a one-line standing-answers note, and compact rows that open in place with Copy link, Pin and Archive as 30 px icon buttons.

Strengths:
- It is the smallest change from today. Each card is still a card, so the code and the drawer stay simple.
- It shows all the context of a card without a click. The option details are readable without opening each one.
- The card height falls from about 800 px to 480-540 px.

Findings fixed:
- The header and the source row were two lines with the ticket title. They are now one line, and the ticket title moved into the chip tooltip (saves 26 px per card).
- On the ended card the header wrapped to 3 lines and the time sat alone on the last line. The time now sits after the priority, and "build under X" became "build", because "answer goes to X" already names X.
- The chore card had a footer row with only Done in it. Done and the text buttons are now on one row.

Findings left open:
- At 1440, 1 card shows in full and the second only starts (severity 2, A9 only half met).
- At 820, a wrapped header line starts with "·" (severity 1).
- Three negative actions (Decline, Wrong question, Withdraw) sit near each other (severity 2, Hick). See open question 3.

### B. Context on the side

A wider card (1080 px) with two columns. The question and the full options are on the left. The side column holds the ticket title, the source row, What and Why now (3 lines, all on hover or focus), "More: …", and the three text buttons. The footer is one row: Note, Always, Answer, Decline. Under 1100 px it folds into the A layout. Answers: the list is on the left and the selected answer is in a sticky reading pane. At 820 the pane is not used and an answer opens as its own page with "← Answers".

Strengths:
- It has the most room for option details at 1440: no clamp, and most details fit on 1-2 lines.
- The cards are shorter than in A at 1440 (405-440 px), and the second card is almost fully in view.
- The reading pane suits long answers, such as the 6-row roadmap table.

Findings fixed:
- The side column first showed all context unclamped, so the cards were 680 px. Now What and Why now clamp, and the rest folds.
- In the side column, "● live" broke across lines. The dot and the word are now one unit (`bb-nw`).
- The footer had two rows. In B it is now one row, because the text buttons moved to the side column.

Findings left open:
- The reading order jumps: the question is on the left, and its "why" is on the right (severity 2, continuity).
- The page is wider than Needs you and session detail (1080 vs 768 px), which breaks the column rule in audit B1/B2 (severity 2, Jakob).
- At 820 it is the same as A. The extra code for two layouts buys nothing at that width (severity 1).

### C. Triage list (recommended)

All pending cards are in one bordered list. Each card is one row: kind, question (one line), live dot plus source name (or "ended" / "source unknown"), age and a chevron. One card is open at a time, in A's layout, with a left accent bar and a collapse button. When you answer, the success line replaces the row and the next card opens. Answers: tabs for **Saved answers**, **Your answers** (answered cards, newest first, with your choice and note) and **Always rules**, over one filter row.

Strengths:
- It meets A9 in full: all 7 requests are in the first view at 1440 and at 820, and the open card is the same height as an A card.
- It is one decision at a time (Hick). The open card gets full attention, and the rows show what comes next (Zeigarnik: the list shows that work is still open).
- The success line stays where the card was, and the next card opens under it (peak-end: each answer ends with a clear "sent to X").
- Ended and unknown sources show on the row, before you open the card.
- The drawer uses the same row, so the drawer and the page match.

Findings fixed:
- The open card had no way to close. It now has a collapse button (chevron up, 26 px) in its header.
- At 1440 the "Copied" panel was under the fold. The page now scrolls the open card to the top when a panel opens.
- At 820 the ticket panel showed twice (sheet plus inline column). Now only the sheet shows under 1024 px.
- On the "Your answers" tab, Show archived showed but does nothing there. It is now hidden on that tab.

Findings left open:
- To compare two pending cards you must open them one after the other (severity 2). In the mockup a row click closes the open card. The build can let a row click keep the first card open, so that two can be compared.
- At 820 the row question cuts off at about 40 characters (severity 1). Its full text is in the tooltip.
- The skeleton bars in the light-theme footer have low contrast (severity 1). They now use `--border-base`.

## Ticket findings: how each option fixes them

| Finding | A Compact | B Side | C Triage |
|---|---|---|---|
| A1 Go to session fails after the click | Name is a link to `/sessions/:id`; focus icon is off with a reason when the pane is closed | same | same, plus live/ended dot on the row |
| A2 Session named 3 times | One source row, merged into the header line | One source row in the side column (header under 1100) | One source row in the open card; name only on the row |
| A3 Unknown source shows tmux command | "The board does not know which session asked this. Find the session"; copy only for Ask about this | same | same; row says "source unknown" |
| A4 "This session has ended." dead end | "ended 4 d ago · answer goes to support-board-coord" (full time on hover) | same | same; row says "· ended" |
| A5 Five copy patterns, no Copied | One field + Copy → Copied 2 s; selects on clipboard fail; Copy link on Answers | same | same |
| A9 One card fills the screen | 480-540 px cards; 1 full + 1 partial at 1440 | 405-440 px; 1 full + 1 almost full at 1440 | all 7 in view at 1440 and 820 |
| A10 Panel covers the page at 820 | Right sheet 460 px, sidebar stays | same | same |
| (c)1 Answers inputs invisible, centred | Left-aligned, `bb-filter-control`, `bb-switch` | same, filters on top of the list column | same, under the tabs |
| (c)2 Info and error flash look the same | Green/red/sunken fills with icons | same | same |
| (c)3 Always checkbox gap | 8 px gap, label "Always use this answer" | same | same |
| (c)8 Kind words Internal / Unsorted | Kind row removed | same | same |
| (c)9 Wrong question / Ask outside the card | In the footer strip inside the border | In the side column inside the border | In the open card's footer |
| (c)10 Drawer repeats full cards | Compact rows with Open | same | same row as the page list |
| (c)12 Paths break mid-word | `overflow-wrap:anywhere` + `<wbr>` after `/` | same | same |

Out of scope here: (c)4 (empty "Expected remote commit" row): the push card hides it in the mockup, but the fix is in `request_card.ex` and is one line. The "Waiting on you without a card" section follows fm-fdw.

## First view: cards visible

Measured in the mockup (7 pending cards). "Starts" = top edge in view; "full" = whole card in view.

| Option | 1440x900 | 820x1180 |
|---|---|---|
| Today (audit) | 1 starts, 0 full (798 px card) | 1 starts, 0 full |
| A Compact | 2 start, 1 full | 2 start, 1 full |
| B Side | 2 start, 1 full (second ends at 905 px) | 2 start, 1 full |
| C Triage | 7 of 7 (1 open + 6 rows) | 7 of 7 |

## Copy for each state (recommended option C)

| State | Where | Copy |
|---|---|---|
| Empty | list | **Nothing waits on you.** New questions and approvals from sessions show here. |
| Loading | list | Two skeleton cards; screen reader: "Loading cards…". LiveView renders on the server, so this shows only after a reconnect. |
| Sending | open card | Answer button: "Answering…" (Approve: "Approving…", Done: "Saving…"), disabled. Choice, note and Always stay; the options dim. |
| Answer sent | in place of the row | ✓ **Answered: B + A's round grouping.** Sent to foreman-board just now. It moves to Recent outcomes. The next card opens. |
| Sent, ended source | same | ✓ **Answered: Update affected tests.** Sent to support-board-coord as a note, with the question. |
| Error | top of the card footer | ⚠ **Your answer was not sent.** The board could not save it: the database did not answer in 5 s. Your choice and note are still here. [Try again] |
| Copied (unknown source) | Ask about this panel | The board cannot send this question, because it does not know which session asked. Copy it and paste it in the agent's chat. [Copy] → "✓ Copied" for 2 s. |
| Ask about this (known source) | panel | Label "Ask about this"; [Send question] (busy "Sending…"); hint "Goes to foreman-board. The reply shows on this card." |
| Wrong question | panel | Label "What is wrong with the question?"; [Send as wrong question]; hint "The card closes and the agent gets your reason." |
| Withdraw | panel | Label "Reason"; [Withdraw card]; hint "The card closes. The agent gets the reason." |
| Focus icon off | tooltip + aria-label | "The pane is closed" |
| Answers: no match | list | **No answers match “zoho”.** Search looks in questions and answer text. Clear filters |
| Answers: loading | list | Four skeleton rows; "Loading answers…" |
| Answers: error | list | ⚠ **Could not load answers.** The database did not answer. Your filters are kept. [Try again] |
| Answers: archived | toast, bottom right, 5 s | ⓘ Archived “What is the guest-email work (8ec.25) and why is it on hold?”. Undo |
| Answers: copied link | next to the icon | "Copied" for 2 s; the icon turns to a check |
| Standing answers empty (A, B) / Always rules empty (C) | line | None yet. To add one, tick Always use this answer when you answer a card. |

Times use the shared format (3 min ago, full time on hover). Failure messages stay until the next action. Success lines stay for 10 s and then the item moves to Recent outcomes.

## Laws that changed the design

- **Common region:** every card action is in the card border, in one footer strip.
- **Hick:** in C, one card is open at a time, and the text buttons are quieter than Answer and Decline.
- **Von Restorff:** one filled button per card, and one accent bar on the open card or the picked option.
- **Proximity:** What and Why now sit right under the question, and the rest folds.
- **Fitts:** icon buttons are 26-30 px, over the 24 px pointer minimum, and the text buttons have a 30 px hit area.
- **Tesler:** the board parses What and Why now and works out where an answer goes. The user does not copy tmux commands.
- **Peak-end:** each answer ends in a line that says what was sent and to whom.
- **Jakob:** the Needs-you column stays at 768 px in A and C. This is the reason B is not recommended.

## Recommendation: C, triage list, with A's card as the open card

C is the only option that meets A9 (all 7 requests in view at both widths). It keeps A's single-column card for the one being answered, so the card itself is as readable as A. It reuses the same row in the drawer ((c)10), which leaves one component instead of two. For Answers, C's tabs also answer a real gap: there is no place to find a decision you made yesterday, and there are 271 answered cards. If Ryan does not want the "Your answers" tab, use A's Answers page under C's Needs-you page. They share the filter row and the row style.

## Open questions for Ryan

1. **Option:** C triage list (recommended), A compact card, or B context on the side?
2. **Context source:** should the board parse What / Why now / Part of / From from the card text (works on today's cards), or should `foreman ask` take them as separate fields (`--what`, `--why-now`), which the board then shows without a parse?
3. **Negative actions:** keep Decline, Wrong question and Withdraw as three actions, or merge Wrong question into Decline with a reason field?
4. **Answers page:** add the "Your answers" tab (answered cards) next to Saved answers, yes or no?
5. **After you answer in C:** open the next card by itself (recommended), or close all and let you pick?
