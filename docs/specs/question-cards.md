# Spec: question cards on Needs you, and the Answers page (fm-zgd.17)

Ticket: `tickets/fm-zgd.17.md` · Design pack: `docs/specs/question-cards.design.md` · Mockup and critique: `docs/specs/question-cards-mockups/` (`question-cards.html`, `question-cards-critique.md`), published at https://claude.ai/artifact/KkSwALbmBHC1TZg1vJf3jW · Audit: `docs/specs/sessions-view-audit/ux-audit.md` · Status: draft for approval, 2026-11-03.

## Goal

The pending cards on Needs you become one triage list with one open card at a time, in a compact layout, and the Answers page gets three tabs (Saved answers, Your answers, Always rules), with the audit findings fixed.

## Why

Ryan, 2026-11-03: "the questions UI is looking kinda rough". The card grew one part at a time. It is now about 800 px tall, so one card fills the screen at 1440. It names the asking session three times. Its "Go to session" button fails only after the click. Two of its actions sit outside its border. On Answers, the filter inputs cannot be seen, and there is no place to find a decision you made yesterday (271 answered cards).

Success for Ryan: he opens Needs you and sees every pending card in the first view. He reads one card, answers it, sees a line that says what was sent and to whom, and the next card is already open. Before he clicks, he knows if the asking session is live or ended. On Answers, he can find a past decision and its note.

## Non-goals

- The section under the cards that was "Waiting on you without a card". fm-fdw replaced it with "Pull requests for you to merge" (on main since 9c27e13). Do not change it.
- The Sessions pages (`/sessions`, `/sessions/:id`), the session identity table, and the data and copy of the card source row. The Sessions spec (`docs/specs/sessions-view.md`, Decisions 1-9, 21, 22) owns them. This spec places the source row in the new card and uses a fallback until that work ships (Decision 14).
- Phone width. Desktop only: 1440 and an 820 window, light and dark.
- New `foreman ask` fields, a CLI rebuild, or a change to the ask lint.
- A schema change or a migration.
- A change to the request lifecycle machine (its states, events and effects). The cards fire the same events as today.
- Recent outcomes: it stays as it is. Its raw state words (audit A7) belong to the Sessions work.
- The push card's empty "Expected remote commit" row (audit (c)4). It is a separate one-line fix.
- Anti-goal: a list that moves under your pointer. If a poll, a new card or a card that closed elsewhere can close, move or reset the card you are reading, the work failed, even if every element is present.

## Decisions

Each decision is marked (user) when Ryan made it, or (agent call) when the coordinator or this spec made it. Dates and cards for the user decisions are in the ticket Notes.

### A. The triage list

1. **Layout C, triage list (user).** All pending cards are in one bordered list in the Needs you column (max 768 px, left-aligned, as today). Each card that is not open is one row: kind badge, question (one line, cut with an ellipsis, full text in the tooltip), source, age, and a chevron down. The age uses the shared human time format with the full time on hover. At 820 the source moves to a second line under the question.
2. **Row source text (user, from "Live or ended").** Live: a green dot and the session name. Ended: a grey dot and "<name> · ended". Unknown source: a grey dot and "source unknown". No state badge.
3. **One card open at a time (user).** A row click (or Enter or Space on a focused row) closes the open card back to its row and opens the clicked one. The open card has a 3 px primary accent bar at its left edge and a "Close card" icon button (chevron up, 26 px) at the right end of its header. Close card leaves all cards as rows.
4. **After you act, a result line takes the card's place and the next card opens by itself (user).** The result line stays for 10 s, then goes. The card is then in Recent outcomes.
5. **Which card is "next" (agent call).** The board takes the list order at the time of the result. Next is the row under the resolved card. If the resolved card was the last row, next is the first row. If no card is left, the empty box shows under the result line.
6. **List order (agent call).** Keep today's order: ticket priority, then oldest first, with the cards of one ticket kept together. Remove the per-ticket heading above a group: the open card header shows the ticket title.
7. **The open card is in the URL (agent call).** The page keeps `?card=<id>` in the URL and patches it when a card opens or the next card opens. Close card removes the parameter, and the list stays closed. On page load with no `card` parameter, the first row opens; later URL changes with no `card` parameter do not open a card. The `ticket` and `doc` panel parameters stay next to `card`; opening or closing a panel does not change the open card. If `card` names a card that is no longer pending, the first row opens and an info line shows above the list (copy in Decision 31).
8. **Your input is kept per card (agent call).** The board keeps each card's choice and the text in its text box on the server, by card id, while the page is open. Closing a card or opening another one never loses this input. A poll never resets the open card's form (today's rule, kept). Amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918): cards have no Always tick and no panels, so the input is the choice and the one text.
9. **New cards (agent call).** A card that arrives by poll or notification joins the list as a row, in list order. It never closes, moves or replaces the open card. When the list was empty, the new card opens.
10. **The open card closes without your action (agent call).** Another tab answered it, the agent withdrew it, or its facts changed. An info line takes its place and the next card opens (Decision 5). If you had typed a note, the line shows it so that you can copy it. Copy in Decision 31.
11. **The list sits on a declared machine (agent call, house rule).** See "State: card list" below. The Ask send state sits on a second machine (Decision 40, amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918)). Today the list keeps its state in loose assigns (ids, versions, headings) and every card is open.

### B. The open card

12. **Compact layout from option A (user).** From top to bottom, all inside one border:
    1. Header line: kind badge · ticket chip · priority badge · ticket title (one line, ellipsis, full title in the tooltip) · age · Close card button. It is one line at 1440. At 820 it wraps, and no wrapped line starts with "·".
    2. Source row (Decision 14).
    3. "Updated 3 min ago" and "Similar question" markers, when they apply, as small grey text on the source row's right (agent call: they keep today's meaning).
    4. The question (16 px, semibold).
    5. What and Why now, as a short definition list. Each value shows 2 lines at most. When "More context" is open, they show in full.
    6. "More context: <the parts that exist>", folded. It holds Part of, From and the agent notes (the rest of the card text). Its label lists only the parts that exist, for example "More context: Part of, agent notes". When open, its label is "Less context".
    7. The card's document links, as today, then the body for the card's kind (Decision 16).
    8. The card thread (questions you asked with Ask, and the replies), when there is one.
    9. The footer strip (Decision 17).
13. **Context comes from the card text (agent call by the coordinator, 2026-11-03).** The board parses the labelled lines What, Why now, Part of and From from the agent's card text. It uses the same label match as the ask lint (start of a line, any case, optional bold, then a colon). A value runs to the next labelled line or the next blank line. The ask lint requires What, Part of and Why now on decision and batch cards; From is optional. Other kinds can have the labels too. When the text has no What and no Why now, the card shows no list and shows the text under the question as today (first lines, then "Show more"). The board's own context block (Kind, Part of and From from the ticket, and the ticket's "What users see" line) goes away. Thus the kind words "Internal" and "Unsorted" go away (audit (c)8). Paths in the text still become document links.
14. **Source row: "Live or ended" (user).** One row under the header. The session is named once (audit A2).

    | Source | Row |
    | --- | --- |
    | Live | Asked by **<name>** · <role> · ● live, then the Focus terminal icon button (26 px, on) |
    | Ended, cannot resume | Asked by **<name>** · <role> · ○ ended 3 min ago · answer goes to <coordinator>, then the Focus terminal icon off, with title and label "The pane is closed" |
    | Ended, can resume | Asked by **<name>** · <role> · ○ ended 3 min ago · your answer resumes it; Focus icon off (Decision 15) |
    | Main coordinator ended, cannot resume | Asked by **<name>** · main coordinator · ○ ended 3 min ago; Focus icon off |
    | Unknown | The board does not know which session asked this. **Find the session** (a link to `/sessions`) |

    The name is a link to `/sessions/:id` (audit A1), so no click fails. The role words are the Sessions spec's: main coordinator, epic coordinator, coordinator, or build under <coordinator>. The time is the shared format with the full time on hover (audit A4). No tmux command shows on a card at load (audit A3). The rows of the triage list (Decision 2) show only the name, not a link, because the whole row opens the card.

    **Dependency on the Sessions spec.** The Sessions spec, step 2 (detail page), ships this row's component and its data (its Decision 21), on the session identity of its step 1 (`agent_sessions`, and `agent_session_id` on each request). Neither is built at 9c27e13. This spec places the row in the new card. If this work lands first, the row uses this fallback until Sessions step 2 ships (agent call). One function gives the card its source view (kind of source, name, role, link, end time, receiver, focus on or off), so the change to the real identity is in one place.

    | Part | When the Sessions work ships | Fallback until then |
    | --- | --- | --- |
    | Name | link to `/sessions/:id` | plain text, not a link |
    | Role | the session kind word from the Sessions spec | the harness word the board knows today (claude, pi) |
    | Live or ended | the session state | today's source lookup: ended when the session's dispatch row has an end time |
    | Ended time | the session end time | the dispatch row end time |
    | "· answer goes to <coordinator>" | the parent coordinator | not shown |
    | Find the session | link to `/sessions` | not shown; the sentence stays |
    | Result line receiver | Decision 30 | Decision 30, fallback rows |

15. **Ended session that can resume (agent call, the same as Sessions Decision 21).** The Sessions rule R9 says: when a session with an open card can resume, answering resumes it first and then delivers the answer; when it cannot, the answer goes to its parent coordinator as a note. Ryan's pick names the second case. For the first case the row says "○ ended 3 min ago · your answer resumes it".
16. **Body by kind (agent call: today's parts in the compact layout).**

    | Kind badge | Body | Primary button (busy text) | Decline | Always (removed (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918)) | Wrong question | Withdraw |
    | --- | --- | --- | --- | --- | --- | --- |
    | Decision | options as compact rows: radio, label, detail (2 lines, full when picked or focused), "Recommended" badge | Answer (Answering…) | yes | yes | yes | when the agent asked |
    | UI review | the review image grid, then the options | Answer (Answering…) | yes | no | yes | when the agent asked |
    | Batch | the items as compact checkbox rows | Submit (Submitting…) | no | no | yes | when the agent asked |
    | Chore | the numbered steps | Done (Saving…) | no | no | yes | when the agent asked |
    | Push, Open PR, Merge | the facts list for the kind | Approve (Approving…) | yes | no | yes | when the agent asked |
    | Session waiting | the waiting facts; for one single-choice question, its options as buttons and an "Other" field; for a chat question, a Reply field | by reason: option button or Reply (Sending…); Continue (Continuing…) at a usage limit; otherwise Open session (Opening…) | no | no | yes | when the agent asked |

    Amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918): no card shows Always. Standing answers made before keep working: the ask is still refused with the standing answer, and they stay on the Answers page (fm-zgd.17.5). Every kind, session waiting included, has the one text box and Ask (Decision 17).

    Decline, Wrong question and Withdraw show where they show today. "When the agent asked" is today's rule: the card's actor is an agent. A merge Approve still goes to the confirm step on Pull requests.
17. **Footer strip (user, negative actions "Keep three, Decline first"; amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918), "The button decides").** One sunken strip at the bottom of the card, inside its border (audit (c)9).
    - Row 1: one text box (placeholder "Note, question or reason") on every kind, then the primary button (filled), then Decline (outline) where the kind has it, then Ask (outline, busy "Sending…"). Session waiting cards keep their Reply or Other field in the body.
    - The button decides what the text is for. The primary button and Decline send the choice with the text as the note. Ask sends the text to the asking session as a question; the card stays open and the reply shows in its thread (Decision 18 for where it goes and what shows). Wrong question and Withdraw send the text as their reason.
    - Row 2: at the right end, small text actions: Wrong question, then Withdraw. Each is 30 px high.
    - Ask, Wrong question and Withdraw are off until the text box has text.
    - No panels open from the footer, and no card shows "Always use this answer".
    - An error line (Decision 32) shows at the top of the strip, over row 1.
    - Only one filled button per card.
18. **Ask and its copy (agent call: copy from the critique; amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918): no panels).** Ask sends the text box.

    | Source | What Ask does | What shows under the footer |
    | --- | --- | --- |
    | Live | sends `[card question <id>] <your text>` to the session; the text box clears | nothing; the question shows in the thread. Ask's title: "Goes to <receiver>. The reply shows on this card." |
    | Unknown | does not send | "The board cannot send this question, because it does not know which session asked. Copy it and paste it in the agent's chat." and the copy field |
    | Ended, fallback until the Sessions work ships | does not send | "The session that asked has ended, so the board cannot send this question. Copy it and paste it in the agent's chat." and the copy field |
    | Wrong question | — | Busy text "Sending…". The card closes and the agent gets the text as the reason. |
    | Withdraw | — | Busy text "Withdrawing…". The card closes and the agent gets the text as the reason. |

    The copy field holds `[card question <id>] <your text>`. When a send fails (the window is closed, the session is not at its prompt), an error line with the reason and Try again shows under the footer, with the same copy field, and the text stays. Error lines: "The question was not sent. The session window is closed." / "The question was not sent. The session is not at an empty prompt." / "The question was not sent. The board cannot reach the session."
19. **Focus terminal (agent call).** The icon focuses the session's terminal, as "Go to session" does today. The "Go to session" button goes away. If focus fails after the click, an info line shows under the source row: "Could not focus the terminal. The window is closed." / "Could not focus the terminal. tmux does not answer." / "Could not focus the terminal. No terminal is attached." For the last one, until the session page ships, the line has the one copy field (Decision 22) with the attach command. After the session page ships, the attach command lives only there (audit A5).
20. **Session waiting notices (agent call: today's notices in the shared line style).** "The question is no longer on screen. Open the session to answer it." / "The session is not at its prompt. Open the session to reply." / "The session window is closed." / "tmux does not answer. Try again." / "No terminal is attached." with the copy field for the attach command, as in Decision 19.

### C. Shared fixes (agent call: the critique's fix table, all in scope)

21. **Three status line styles (audit (c)2).** Success: green-soft fill, check-circle icon. Error: red-soft fill, warning icon, and a Try again button when a retry can work. Info: sunken fill, info icon. Colour is never the only cue. The board flash group uses the same three styles, so info and error flashes no longer look the same.
22. **One copy pattern (audit A5).** A read-only mono field and a Copy button. On click, the button text changes to "Copied" with a check icon for 2 s. If the clipboard fails, the field text is selected so that you can copy it by hand. This is a client hook, not board state. Every copy box on the changed screens uses it. On cards it shows only when the board cannot send (Decisions 18, 19, 20).
23. **Always checkbox (audit (c)3).** Label "Always use this answer". 8 px gap between the box and the label. Superseded (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918): cards have no Always checkbox (Decision 17).
24. **Long ids and paths (audit (c)12).** Use `overflow-wrap: anywhere`, with a word-break opportunity after each "/". Do not use `break-all` on the changed screens.
25. **Ticket and document panel under 1024 px (audit A10).** A sheet on the right, `min(460px, 100% - 96px)` wide, over a scrim. The sidebar and the left edge of the list stay in view. Esc, the X and a click on the scrim close it. At 1024 px and wider it stays in the right column, as today. Only one copy of the panel shows at any width.
26. **Board parts only.** Use `Layouts.app`, `bb-nav`, the Fluxon badges and buttons, the ticket chip, board tokens and `bb-` classes in the board stylesheet next to `.bb-panel`. No new hex colours. The mockup lists the parts it uses.
27. **Request drawer uses the same rows (user; drawer behaviour agent call, open for Ryan).** The drawer shows one row per pending card, with no full cards (audit (c)10). Because the drawer is narrow, the row is stacked: the kind badge, source and age on one line, the question under it, and "Open" at the right. When the Sessions work ships, the source name in a drawer row is a link to `/sessions/:id` (Sessions Decision 22); the rest of the row opens the card. The header has "Needs you", the count badge, "Open full page" and Close. A row click or Open goes to Needs you with that card open (`?card=<id>`) and closes the drawer. On Needs you itself, it patches the page. The drawer no longer answers cards, so its own answer handler and its "Request not updated" line go away. See "Open for Ryan" 1.
28. **No "user" actor word (agent call).** The changed screens do not show the request's actor word ("user", "claude", "pi") as a label. The source row names the session. The only exception is the fallback role in Decision 14, which shows the harness word until the Sessions role words exist.

### D. Needs you: states and copy

29. **Page states.**

    | State | Where | What shows (exact copy) |
    | --- | --- | --- |
    | Default | list | Every pending card as a row; the first (or the `card` one) open. The h1 count badge counts pending cards, as today. |
    | Empty | list | Dashed box: **Nothing waits on you.** New questions and approvals from sessions show here. |
    | Loading | list | Two skeleton blocks (an open-card shape and two rows), bars in `--border-base`. Screen reader: "Loading cards…". It shows only while the list has not loaded (first connect, reconnect), never on a poll. |
    | List load failed (agent call) | above the list | ⚠ **Could not load cards.** The database did not answer. The list shows the last cards it loaded. [Try again] |
    | Sending | open card | The primary button shows its busy text (Decision 16) and is disabled. Choice and text stay. The options dim. |
    | Error | top of the footer strip | Decision 32. |
    | Result | in place of the card | Decision 30. |
    | Closed elsewhere | in place of the card | Decision 31. |
    | Stale card link | above the list | Decision 31. |
    | Ticket panel at 820 | right sheet | Decision 25. |

30. **Result line copy.** Success style. Bold first sentence, then the receiver, then "It moves to Recent outcomes." The time is "just now" in the shared format.

    | Your action | First sentence |
    | --- | --- |
    | Answer | **Answered: <your choice>.** If you picked no option and wrote a note: **Answered with your note.** |
    | Submit (batch) | **Answered: <n> of <m> items.** |
    | Approve, push | **Approved: Push.** |
    | Approve, open PR | **Approved: Open PR.** |
    | Done | **Marked done.** |
    | Decline | **Declined.** |
    | Wrong question | **Sent as wrong question.** |
    | Withdraw | **Withdrawn.** |
    | Reply (session waiting) | **Replied: <option or your text>.** |

    | Receiver | Second sentence |
    | --- | --- |
    | Live session | Sent to <name> just now. |
    | Ended, answer goes to the coordinator | Sent to <coordinator> just now, as a note with the question. |
    | Ended, your answer resumes it | Sent to <name> just now. The board resumes it first. |
    | Approve | The board starts it now. |
    | Fallback until the Sessions work ships: ended | Saved just now. The session that asked has ended, so no session gets it now. |
    | Unknown source | Saved just now. The board does not know which session asked, so no session gets it. |

    Example: "✓ **Answered: B + A's round grouping.** Sent to foreman-board just now. It moves to Recent outcomes."
31. **Info line copy (agent call).** Info style.
    - Closed elsewhere: "ⓘ **This card closed elsewhere.** <Outcome> <time>." Outcome words: Answered, Declined, Sent as wrong question, Marked done, Approved, Withdrawn by the agent, Replaced because its facts changed. If you had typed a note, a second line: "Your note was not sent:" and the note in the copy field (Decision 22). The line stays until you act on the next card or close it with its X.
    - Stale card link: "ⓘ That card is no longer open. Find it in Recent outcomes." It stays until the next action.
    - Continue sent (usage limit): under the source row, "Sent Continue to <name> just now." The card stays open, because the request stays pending.
32. **Error line copy (agent call).** Error style, with Try again (it sends the same action again with the kept input).
    - First sentence by action: Answer and Submit "**Your answer was not sent.**" · Approve "**Your approval was not sent.**" · Decline "**Your decline was not sent.**" · Done "**Done was not saved.**" · Reply "**Your reply was not sent.**" · Wrong question "**Your reason was not sent.**" · Withdraw "**The card was not withdrawn.**"
    - Second sentence: "The board could not save it: <reason>." Reasons: the database did not answer (a database timeout or a lost connection); the board does not accept this action on this card (an invalid action or event); only a card from an agent can be withdrawn (withdraw refused). For any other error, the sentence ends after "save it".
    - Third sentence: "Your choice and note are still here." (Chores: no third sentence.)
    - The line stays until your next action on that card. It replaces today's "Request not updated" flash on Needs you.

### E. Answers page

33. **Tabs (user).** Under the h1 "Answers": Saved answers, Your answers, Always rules. Each tab shows its count. The tab is in the URL (`?tab=saved`, `yours` or `rules`; no parameter means Saved answers). The h1 has no count badge, because each tab has one (agent call).
34. **Layout fixes (audit (c)1).** The page is left-aligned in the same 768 px column as Needs you. One filter row under the tabs: Search (with a magnifier icon, label "Search"), Repo (a select: "All repos" and each configured repo), Ticket (a text field), all `bb-filter-control` (border, fill, 36 px). "Show archived" is the `bb-switch` from Settings, with an 8 px gap to its label. It shows only on Saved answers, because the other tabs have no archive (agent call; the critique hid it on Your answers).
35. **Saved answers rows.** Today's answers list in compact rows: a chevron and the question (a button that opens the row in place), then a meta line: repo · ticket chip · "<n> versions" when more than one · time · "Pinned" with a bookmark icon. Pinned rows come first. At the right: Copy link, Pin or Unpin, Archive or Restore, as 30 px icon buttons with titles. An open row shows the answer body, its links, and "Earlier versions (<n>)" folded. Copy link copies the answer's page link (`/answers?id=<id>`); its title and a small "Copied" text show for 2 s and the icon turns to a check. If the clipboard fails, the page goes to that link and the text says "Copy failed. Copy the link from the address bar." (agent call).
36. **Your answers (user; data agent call).** Answered cards of kind decision, UI review and batch, newest first. Each row: the question; "You answered <answer>"; your note in quotes when there is one; a meta line with the ticket chip, "to <session name>" and the time. Rows do not open. The ticket chip opens the ticket. The filters work here: Search looks in the question, the answer and the note. The tab shows 50 rows, then a "Show 50 more" button (agent call).
37. **Always rules.** Today's standing answers under the new name. Each row: the question, the answer, the note, the repo, the time and a Remove button. Remove takes the row away with no toast (agent call).
38. **Answers states and copy.**

    | State | Copy |
    | --- | --- |
    | Loading | Four skeleton rows. Screen reader: "Loading answers…" |
    | Error | ⚠ **Could not load answers.** The database did not answer. Your filters are kept. [Try again] |
    | No match (any tab) | **No answers match “<search>”.** Search looks in questions and answer text. [Clear filters] — when the search is empty and another filter is on: **No answers match these filters.** [Clear filters] |
    | Saved answers, none at all | **No saved answers yet.** Answers that agents save show here. |
    | Your answers, none at all | **You have not answered a card yet.** |
    | Always rules, none | None yet. (Amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918): cards no longer set Always; the copy for this state is fm-zgd.17.5's to settle.) |
    | Archived | Info flash at the bottom right for 5 s: ⓘ Archived “<question>”. [Undo] — Undo restores it. |
    | Copied link | "Copied" next to the icon for 2 s; the icon turns to a check. |
    | Pin, unpin, restore failed | Error flash: ⚠ **Answer not changed.** The answer is not there now. |

### F. Machines

39. **Card list machine (agent call, house rule).** One machine per Needs you page. Proposed name `Foreman.CardList`. It holds which card is open; the result and info lines are its effects.

    | State | Means |
    | --- | --- |
    | `empty` | no pending card |
    | `closed` | pending cards, none open |
    | `open` | one card open, no error |
    | `failed` | one card open; its last action failed |

    | From | Event | Guard | To | Effects |
    | --- | --- | --- | --- | --- |
    | `empty` | `loaded` | some card pending | `open` | open the `card` one, else the first |
    | `empty` | `loaded` | none pending | `empty` | |
    | `closed` | `loaded` | some pending | `closed` | add new rows |
    | `closed` | `loaded` | none pending | `empty` | |
    | `open`, `failed` | `loaded` | the open card is still pending | stay | add new rows; the open card does not change |
    | `open`, `failed` | `loaded` | the open card left, others pending | `open` | closed-elsewhere line (with your note), open next |
    | `open`, `failed` | `loaded` | the open card left, none pending | `empty` | closed-elsewhere line |
    | `closed`, `open`, `failed` | `open_row` | that card is pending | `open` | keep the old card's input, open that card, clear its error line |
    | `closed`, `open`, `failed` | `open_row` | that card is not pending | stay | stale-link line |
    | `open`, `failed` | `close` | | `closed` | keep input |
    | `open`, `failed` | `resolved` | others pending | `open` | result line (goes after 10 s), drop that card's input, open next |
    | `open`, `failed` | `resolved` | none pending | `empty` | result line |
    | `open`, `failed` | `resolve_failed` | | `failed` | error line; keep input |
    | any | `line_expired` | | stay | remove that line |
    | any | `load_failed` | | stay | list-load error line; keep the rows |

    Who fires them: `loaded` and `load_failed` come from mount, the 3 s poll and the event notification (observed). `open_row` comes from a row click, the URL `card` parameter and the drawer Open. `close` comes from Close card. `resolved` and `resolve_failed` come from the result of the open card's primary action, Decline, Wrong question or Withdraw, when the request leaves pending. Continue, Send question and focus keep the request pending, so they do not fire `resolved`. `line_expired` is the 10 s timer.

    Rules, in Ryan's words:
    - R1 At most one card is open at a time.
    - R2 A poll, a new card or a card that closes elsewhere never closes, moves or resets the card you are reading. Only your own action changes the open card.
    - R3 Closing a card or opening another one never loses what you typed or picked.
    - R4 After you act on a card, a line says what was sent and to whom, and the next card opens by itself.
    - R5 When your action fails, the card stays open with your choice and note, and the line says why.
    - R6 A card never vanishes without a line that says why.
    - R7 When nothing waits on you, the page shows the empty box and no open card.
    - R8 A result line goes after 10 s; the card is then in Recent outcomes.
    - R9 An error line stays until your next action on that card.
40. **Ask machine (agent call; replaces the footer panel machine, amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918)).** `Foreman.CardAsk`, one per open card. No footer panel opens any more, so `Foreman.CardFooterPanel` and its rules P1 and P2 are gone. States `idle`, `copy` (the source cannot get the question: show the hint and the copy field) and `failed` (the send failed: show the reason, Try again and the copy field). Events `sent` (to `idle`, clears the text box), `unsendable` (to `copy`), `failed` (to `failed`) and `card_closed` (to `idle`, keeps the text, Decision 8). Only `sent` clears the text.
41. **Answers tab machine (agent call).** Proposed name `Foreman.Answers.Tab`, URL-driven like the ticket panel machine. States `saved`, `yours`, `rules`; event `select(tab)` from any state. The existing answer expansion and pin/archive machines stay as they are. The request drawer and ticket panel machines stay as they are; only what they show changes.
42. **Generated machine docs.** The new machines get their generated pages in `docs/machines/` from the machine docs task, as the other machines do.

### G. Element ids (agent call, for tests)

43. Keep `pending-requests`, `inbox-empty`, `request-drawer`, `drawer-full-page`, `answer-filters`. New: `card-row-<id>`, `card-open-<id>`, `card-close-<id>`, `card-source-<id>`, `card-focus-<id>`, `card-result-<id>`, `card-error-<id>`, `card-info-<id>`, `card-ask-<id>`, `card-wrong-question-<id>`, `card-withdraw-<id>`, `cards-error`, `drawer-row-<id>`, `answers-tab-saved`, `answers-tab-yours`, `answers-tab-rules`, `your-answer-<id>`, `always-rule-<id>`. Drawer ids keep the `drawer-` prefix.

## Acceptance checks

1. **First view (audit A9).** Baseline from the audit: at 1440x900, 1 card starts and 0 cards show in full (the push card is 798 px). After: with 7 pending cards, all 7 show in the first view at 1440x900 and at 820x1180 (1 open card and 6 rows), as in the mockup measure. The open decision card is at most 540 px tall at 1440.
2. **Findings.** Each ticket finding has its fix in place: A1 (14), A2 (14), A3 (14, 18), A4 (14, 30), A5 (22), A9 (check 1), A10 (25), (c)1 (34), (c)2 (21), (c)3 (23), (c)8 (13), (c)9 (17), (c)10 (27), (c)12 (24). A push card with a long worktree path shows it at 820 with breaks only after "/" or where the line has no other place to break.
3. **No dead click.** No card at load shows a tmux command, "Go to session", "Source unknown ·" or "This session has ended.". An ended source shows its end time in the shared format and the Focus icon off with "The pane is closed".
4. **One at a time.** On Needs you with 3 cards: exactly one `card-open-*` element exists. Clicking a row makes that card the only open one.
5. **Next opens.** Answer the open card: `card-result-<id>` shows the copy from Decision 30, the row under it is now open, and after 10 s the result line is gone and the card is in Recent outcomes.
6. **Input kept.** Pick an option and type a note on card 1, open card 2, open card 1 again: the option and note are still there. A poll in between does not change them.
7. **Poll does not move the open card.** While card 2 is open, a new card arrives with a higher priority. Card 2 stays open; the new card is a row.
8. **Closed elsewhere.** Answer the open card from a second tab: the first tab shows the closed-elsewhere line with "Answered" and opens the next card.
9. **Failure.** Make the answer fail (test double): the card stays open with `card-error-<id>`, the choice and note, and Try again sends it again.
10. **Copy.** On an unknown-source card, type text and press Ask: the copy field shows the text, and Copy changes to "Copied" for 2 s (amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918)).
11. **Drawer.** The drawer shows rows only (no `decision-*` form inside it). Open on a row lands on `/needs-you?card=<id>` with that card open.
12. **Answers.** Three tabs, each with a count. The filter inputs have a visible border at 1440 and 820 in light and dark. Show archived shows only on Saved answers. Your answers lists answered decision cards newest first with the answer and note. No row shows the word "user" as an actor.
13. **820.** The ticket panel opens as a right sheet; the sidebar and the left edge of the list stay visible; Esc closes it.
14. **House rules.** Every time on the changed screens uses the shared human format with the full time on hover. No tagline or how-it-works text is added. `mix foreman.fsm.docs` output includes the three new machines.
15. **From outside the code.** Ryan answers a real pending card on the board in his browser and sees the result line and the next card open, with no other change to the page.

## Verification plan

- **Seams (fewest, highest).**
  1. The three new machines: table tests through their `step/3`, one per row of the state tables, plus a test per rule (R1–R9 where the machine can show it). `Foreman.CardAsk` gets one test per row (amended (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918); P1 and P2 went with the footer panels).
  2. The context parser: unit tests with real card texts from `foreman_dev` (bold labels, plain labels, labels in any case, no labels, From missing, a value over two lines).
  3. The source view function: one test per row of the fallback table, and one per Sessions row once that work ships.
  4. LiveView tests through the existing files for Needs you, the request drawer, card questions, card lifecycle and Answers, using the element ids in Decision 43. Update the selectors of existing tests where elements moved; keep what they assert.
- **Screens.** `verify ui --matrix` on Needs you (default, open card, result, error, empty, ticket panel) and Answers (each tab, no match), and the drawer, at 1440 and 820, light and dark, before and after. Compare with the mockup PNGs in `docs/specs/question-cards-mockups/` (`C-*`). Put the screenshots on the push card (ticket acceptance).
- **First-view measure.** With 7 pending cards in a seeded dev database, count the cards whose top edge is in the 1440x900 and 820x1180 views.
- **Where.** Builds run in a worktree with its own dev server (`devserve`). Do not run mix or migrations in the checkout that runs Ryan's live board.
- `mix precommit` passes.

## Ask-first boundaries

- Any change to `foreman ask`, the ask lint, or the card text format.
- A migration, a new table or a new column.
- A change to the request lifecycle machine.
- Any change to the "Pull requests for you to merge" section, Recent outcomes, or the Sessions pages, or a change to the source row copy that the Sessions spec owns.
- Answering inside the drawer again, or a different drawer behaviour from Decision 27.
- Showing two open cards at once.
- Removing an action from a kind where it shows today.
- Deleting a test instead of updating its selectors.
- A phone layout.

## Left to the builder

- How the card, row and drawer row components are split, and their names.
- Where the per-card input is stored on the server, and how the 10 s timer runs.
- How the list loads so that the loading and list-load-failed states can show.
- The new `bb-` class names and the exact skeleton shapes, inside the board tokens.
- The keyboard detail past Decision 3 (for example, arrow keys between rows), as long as rows are reachable with Tab and open with Enter or Space.
- How the drawer passes `card` when the page under it is Needs you.

## Open for Ryan

None.

Settled by the coordinator before approval (agent call): **the drawer opens the card on Needs you.** Drawer rows go to `/needs-you?card=<id>` with that card open; the drawer no longer answers cards. This follows the Sessions spec non-goal "Needs you stays the one place to answer cards" and the mockup.
