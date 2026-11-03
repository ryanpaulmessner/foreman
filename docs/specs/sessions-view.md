# Sessions: live tree, session detail, and links that work

Status: draft for approval, 2026-11-03. Wayfinder map: fm-9mm. Design pack: `docs/specs/sessions-view.design.md`. Decisions come from the map's decision tickets (fm-9mm.1 to fm-9mm.8) and the source row pick on fm-zgd.17. This spec absorbs fm-knr, fm-zgd.10 (read-only half), fm-3c3.8 and fm-3c3.9.

## Goal

Every agent session the board knows has one identity row, one lifecycle, a page at `/sessions/:id` that always opens (live or dead), a place in a live Sessions tree (and later a grid), and controls that work in its current state; every session link on a card, ticket or epic opens that page.

## Why

Session links on question cards fail about 90% of the time. The 2026-11-01 diagnosis (251 decision cards, 14 days) found about 72% broken when the card was created: 82 cards had no session, 40 builds stored their coordinator's name, 59 coordinators were never registered and their names differ from their tmux windows. Ryan wants to see at a glance which sessions work, which wait on him and which are in review, open any of them from a card in one click, and act on it (focus, continue, resume, stop) without reading tmux commands. A detail page alone fixes only the ended-window cases, so the identity fix comes first.

Success for Ryan: a card's "Asked by" name always opens a page that says what that session is doing or when it ended and what he can do next; the Sessions page shows everything that waits on him first.

## Non-goals

- Phone width and working from the phone (map: out of scope). Desktop only, 1440 and an 820 window.
- Starting new Pi builds from the board. Builds are started by coordinators. Resuming an existing Pi session (fm-9mm.2) is in scope; it is not a new build.
- Typing free text into a pane from a terminal in the browser (the interactive half of fm-zgd.10). The board types only Continue, Send message and notes, as below.
- Showing tmux panes the board does not know about.
- Several machines in one tree.
- A second place to answer cards. Needs you stays the one place to answer cards (agent call, made by the coordinator for the map's "Not yet specified" list).
- New notifications for session state changes. Request notifications already cover "waiting on you" (agent call, coordinator).
- Transcript excerpts in the dead view (agent call, coordinator). The dead view keeps the timeline and the last saved pane output.
- Backfill of old requests (fm-9mm.1 D3). The 524 old requests keep their text name.
- A launch form. Launch is one click with defaults (fm-9mm.8).
- A separate launcher on the Sessions page (fm-9mm.8).
- Failure even if it works: any session link that shows an error box, a raw tmux command on a card, a raw state atom on screen, or a second state-colour map.

## Build order

Tickets follow this order. Each step ships on its own and leaves the board working.

1. **Identity** (fm-9mm.1): `agent_sessions`, `session_captures`, the writers, ask resolution, the lifecycle machine and the shared state function (Decisions 1 to 9).
2. **Detail page** (fm-9mm.7): `/sessions/:id` live and dead views, pane output, controls, the card source row and every source link (Decisions 10 to 22).
3. **Tree** (fm-9mm.6 option C): the Sessions page with the "Waiting on you" strip (Decisions 23 to 27).
4. **Launch** (fm-9mm.8): one-click epic coordinator on the epic row and the epic page (Decisions 28 to 31).
5. **Grid** (fm-9mm.6 option D): the Tree · Grid switch and the grid view (Decisions 32 to 34).

## Decisions

### Identity (step 1)

1. **One identity table** (user, fm-9mm.1 D1). A new table `agent_sessions` is the only session identity. Fields: `id` (uuid; for Claude it is also the conversation id), `name` (equals the tmux window name for coordinators and window builds; the build's own `--name` for pane builds), `kind` (`main_coordinator`, `epic_coordinator`, `build`), `parent_id`, `harness` (`claude`, `pi`), `model`, `conversation_id` (Claude uuid or Pi session id), `tmux_server` (`board` or `default`), `pane_id` (always `%N`; the window name is display only), `project`, `ticket`, `workdir`, `branch`, `state`, `started_at`, `last_seen_at`, `ended_at`. `planning_sessions`, dispatch `sessions` rows and `approval_requests` get an `agent_session_id`. The schema and migrations are in the pack's Data part.
2. **Names are unique among live sessions only** (user, D4). A partial unique index on `name` where `ended_at` is null. A name can be reused after the old session ends; old cards keep the old row by id and open its dead view.
3. **Who writes the row** (user, D1).
   - Board launch (main or epic coordinator): in the same transaction as `planning_sessions`.
   - `coord` and `foreman coordinator` outside the board: the launch script calls `foreman session register` with `$TMUX_PANE`.
   - `pi-window` (window or pane build): `foreman dispatch --name <build> --pi-session <uuid>`, and Pi starts with `pi --session-id <uuid>`. The parent is the caller's `FOREMAN_SESSION`, resolved to its row. The build's own name goes in `name`, never `FOREMAN_SESSION`.
   - Relay and slice-loop builds: the relay `open` step calls `foreman session register --parent <coordinator>`.
   - Readers that match sessions by name today (the card source lookup and coordinator notes) read `agent_sessions` instead (agent call).
4. **Board-launched planning sessions** (agent call). Sessions the board launches for a draft epic or an unplanned ticket are `epic_coordinator` rows with the main coordinator as parent. The kind list stays at three values; the role text says "coordinator".
5. **Ask resolution** (user, D2). `foreman ask` always sends `FOREMAN_SESSION` and `$TMUX_PANE`. The server resolves by name among live rows, then by live pane id, and stores `agent_session_id` on the request when it accepts it, never at render. No match: the board accepts the card, the card shows the unknown source row, and the CLI prints a warning: `The board does not know this session (name <name>, pane <pane>). The card shows that the source is unknown.`
6. **Migration backfill** (user, pack Data). `agent_sessions` is filled from the 14 registrations, the 3 planning rows, and dispatch rows that have a pane id and their own name. Requests are not backfilled (D3).
7. **One lifecycle machine** (user, fm-9mm.5; machine shape is an agent call). A new declared `Foreman.Fsm` machine drives `agent_sessions.state` for every kind, with `kind` as a guard. `planning_sessions` keeps its launch and park bookkeeping on `Foreman.SessionMachine`; every SessionMachine transition that changes liveness also fires the matching event on the new machine in the same transaction, and the Sessions pages read only `agent_sessions`. State table (live = the pane exists):

   | From | Event | To | Effects |
   |---|---|---|---|
   | (none) | launch, register | starting | write the row; board launch opens the window |
   | starting, idle | output_changed (observed) | working | |
   | working | quiet: no output change for 2 min (observed) | idle | |
   | starting, working, idle | asked: a card with this `agent_session_id` is accepted | waiting.question | |
   | starting, working, idle | permission_prompt (observed, SessionWaiting) | waiting.permission | session_waiting request |
   | starting, working, idle | usage_limit (observed, SessionWaiting) | waiting.usage_limit | request with provider and reset time |
   | waiting.question | last_card_closed | idle | |
   | waiting.permission | prompt_cleared (observed) | working | clear the request |
   | waiting.usage_limit | continue (user) | waiting.usage_limit | send `continue` and Enter to this pane only |
   | waiting.usage_limit | output_changed (observed) | working | clear the request |
   | waiting.usage_limit | resume_on_model (user, Pi build) | starting | save capture, stop the process, resume the same Pi session with `--model` (Decision 19) |
   | any live, coordinator not main | park (user), idle_timeout (observed) | parked | save capture, close this pane only |
   | any live | stop (user) | ended | save capture, close this pane only; worktree and branch stay |
   | any live | pane_gone, exited (observed) | ended | save capture (exit capture, else last poll) |
   | parked, ended | resume (user) [resumable] | starting | same row; Claude `--resume <id>`, Pi `--session-id <id>` in its worktree |
   | parked, ended, coordinator | start_fresh (user) [not resumable] | (old row stays) | new row with the same name and parent, new conversation; live builds of the old row move to the new row |
   | ended, build | relaunch_build (user) [not resumable] | (row stays ended) | resume the parent first if it is dead, then send the parent the relaunch note |
   | any other pair | | | claimed events refused, observed events ignored |

   `resumable`: Claude needs `conversation_id`. Pi needs `conversation_id`, the worktree and the Pi session file (fm-9mm.2).

   Agent calls on the table: `idle_timeout` keeps today's parking limit. A window closed by hand is `pane_gone` here (ended), while SessionMachine still parks the planning row; both offer Resume. A Pi build's usage limit comes from its coordinator when `pi-wait` exits LIMITED (today's path), and the request names the build's row, not the coordinator's.
8. **Rules** (user, fm-9mm.5; model-checked). In Ryan's words:
   - R1 Every session has exactly one label at all times.
   - R2 An open card always makes the label "waiting on you", even after the session ended; "ended" is the second line.
   - R3 A dead session never offers Focus, Send message, Continue, Park or Stop.
   - R4 Resume shows only when its conditions hold. Otherwise a dead build offers "Relaunch build on this ticket" and a dead coordinator offers Start fresh.
   - R5 Stop never deletes the worktree or the branch.
   - R6 The main coordinator is never parked.
   - R7 At most one live session has a given name (enforced by the index, Decision 2).
   - R8 When a coordinator ends, its live builds keep running and stay under it with "Parent ended". Relaunch build on a dead build resumes its coordinator first, then sends the note.
   - R9 When a session ends with an open card, the card stays open. If the session can resume, answering resumes it first, then delivers the answer. If not, the answer goes to its parent coordinator as a note with the question, and the card closes.
   - R10 Every dead build has Resume, Relaunch build, or is closed out (its ticket stage is committed or later).
   - R11 (agent call) Park and Stop close only the session's own pane, never its window, so pane-mode builds in a coordinator's window keep running (R8). Today's park closes the whole window.
9. **One state function** (user, fm-9mm.4 audit B3). One function maps (state, open cards, ticket stage, ended time) to the label, its colour and its second line. Every page that shows a session state uses it, and the board's other three colour maps are not copied.

   | Label | When | Badge |
   |---|---|---|
   | Waiting on you | any `waiting.*` state, or an open card on a dead session (R2). Wins over all others | solid `primary` with `hero-inbox` |
   | In review | a build that is `idle` and its ticket stage is `reported` or `in_review` | `warning` |
   | Working | `starting` or `working` | `info` |
   | Idle | `idle` and not in review | neutral soft |
   | Parked / Ended | dead states | outline |

   Second lines: `<N> cards · <time>`, `Permission prompt · <time>`, `Usage limit · resets <time>`, `for <time>`, `ended <time>`, `Parent ended <time>`. Every `<time>` on every screen in this spec is the shared human format (relative, full time on hover).

### Detail page (step 2)

10. **Route and layout** (user, fm-9mm.7: option B with A's round grouping). `/sessions/:id`, inside `Layouts.app` with `active={:sessions}`. One column at the Needs-you width. Breadcrumb `Sessions / <coordinator> / <name>` (ids in mono). Heading: the ticket title, or the session name when there is no ticket. Under it: state badge, second line, session name (mono), role, and the live line. Then the next-step panel with at most one filled button, then the controls that work now, then one line for the controls that are off. Then tabs: Recent output, Timeline, Details.
11. **Never an error box** (user, charting). A known id always renders: the live view while the pane exists, the dead view after. Detail pages never expire. An id that was never a session shows the breadcrumb and "The board has no session with this id." (agent call).
12. **Default tab** (agent call, critique fix). Recent output when the session is live and nothing waits on you; Timeline when it waits on you or is dead.
13. **Timeline** (user, from A). Stage events, progress notes, reports, cards and control results, grouped by review round; the current round is open, older rounds are folded. A round starts at a dispatch or a "changes requested" and ends at the next report (agent call).
14. **Recent output** (user, fm-9mm.3). Read-only. While a detail page shows a live pane, the board runs `tmux capture-pane -p -e -J -S -200 -t <pane>` once a second for that pane only, and pushes to the page only when the capture's hash changes. Polling stops when no page shows the pane or the tab is hidden. A board-owned ANSI-to-HTML converter renders SGR colours and OSC 8 links (no new dependency). The output panel is dark in both themes (critique: kept on purpose). The reader is a declared `Foreman.Fsm` machine (off, polling, paused, tmux error; agent call, house rule), shared with the grid in step 5; the pack's State part draws it. The tree's collapse chevrons and the in-page Stop and Start fresh confirms use the board's existing disclosure machine (agent call).
15. **Saved output** (user, fm-9mm.3). `session_captures` keeps the last output per session: saved at agent exit (by the launch command), before Stop and Park, and the latest polled capture as a fallback. The dead view shows it with its source line.
16. **Details tab** (user, audit A5 and A8). Harness, model, project, ticket, branch, workdir, server, pane, conversation id, started, last seen, ended. The attach command uses the one shared copy field: read-only mono text and a Copy button that says "Copied" for 2 s, and selects the text if the clipboard fails. The attach command shows only here, never on cards.
17. **Controls** (user, charting and fm-9mm.7). Allowed states come from Decision 7. Only controls that work now show as buttons; the others go in one line, "Not available now:" followed by `<control> (<reason>)` items. Buttons size to their labels: no fixed widths, labels never wrap or overflow at 1440 or 820 (user, Ryan saw overflow in A). Stop sits apart at the right end. Busy text uses `phx-disable-with`.

    | Control | On when | Off reason | Confirm | Busy | Result |
    |---|---|---|---|---|---|
    | Answer on the card | an open card | No card is open. | | | opens Needs you at the card |
    | Continue | `waiting.usage_limit` (stays on before the reset, user) | Only after a usage limit. | | Continuing… | Sent "continue" to `<name>`. |
    | Resume on `<model>` | Pi build at a usage limit, model has a fallback (Decision 19) | | | Resuming… | Resumed `<name>` on `<model>`. |
    | Resume | dead and resumable | No Pi session id was recorded at launch. / The worktree was removed. | | Resuming… | Resumed `<name>` in `<workdir>`. |
    | Relaunch build on this ticket | dead build, not resumable | | | Relaunching… | Sent `<coordinator>` the note: "Relaunch the build for `<ticket>` on `<branch>`." With R8: Resumed `<coordinator>` and sent it the note. |
    | Start fresh | dead coordinator, not resumable | | in-page: **Start a new conversation for `<name>`?** The old conversation stays in history. [Start fresh] [Cancel] | Starting… | Started a new `<name>` conversation. Its builds stay under it. |
    | Focus terminal | live, tmux answers | The pane is closed. / tmux does not answer. | | Focusing… | Brought `<name>` to the front. No client: No terminal is attached. Copy the attach command from Details. |
    | Send message | `idle`, `waiting.question` | The agent is working. A message now interrupts it. / Use Continue at a usage limit. | | Sending… | Sent to `<name>`. |
    | Park | live coordinator, not main | The main coordinator does not park. | | Parking… | Parked `<name>`. Its builds keep running. |
    | Stop | every live state | tmux does not answer. | in-page: **Stop `<name>`?** The agent stops now and loses work it has not saved. The worktree `<worktree>` and the branch `<branch>` stay. (coordinator: Its builds keep running.) [Stop session] [Keep it running]; focus on Keep it running | Stopping… | Stopped `<name>`. The worktree and branch stay. |
    | Try again now | tmux error | | | Trying… | tmux still does not answer. |

    Park is not shown on builds at all (critique fix). Failure result for any control: "Could not `<verb>` `<name>`: `<reason>`. Nothing changed." Result lines stay until the next action or state change.
18. **Send message delivery** (agent call). A one-line text box under the controls, label `Message to <name>`, with a Send button. It types the text and Enter into this session's pane through the existing reply path, only in the states in Decision 17.
19. **Continue on another model** (user: "have a way to fallback to other models"; mechanics are an agent call). Continue always stays on and the page shows the reset time.
    - Pi builds: "Resume on `<model>`" saves the capture, stops the Pi process, and resumes the same Pi session in its worktree with `--model <model>`; the row's `model` changes. The fallback pairs live in board config, starting with `openai-codex/gpt-6-astra` and `anthropic/claude-opus-5-5` as each other's fallback. No pair for the current model: no button.
    - Builder check first, before this control is built (fm-9mm.2 left these unverified): in a scratch worktree, confirm that `pi --session-id <id> --model <other>` keeps the conversation and uses the new model across providers (cross-provider thinking replay). If it does not, the button becomes "Relaunch on `<model>`" and goes through the coordinator as a relaunch note that names the model.
    - Claude coordinators: what a fallback means is not known. Builder check first: does `claude --resume <id> --model <other>` keep the conversation and switch the model, and does an Anthropic usage limit block every model on the account or only one? Post the result as a decision card for Ryan. Until he answers, Claude sessions show Continue only.
20. **Where a resumed Pi build opens** (agent call). In a new pane of its parent coordinator's window when that window is live (pane mode), else in a new window with the build's name in the project's session on the server where it ran. The row keeps its id; `pane_id` changes.
21. **Card source row** (user, fm-zgd.17 card 86cedfd3; replaces Go to session, audit A1 to A4). One row on every request card, no state badge:
    - Live: `Asked by <name> · <role> · ● live` and a Focus icon (26 px target, title "Focus terminal").
    - Ended, cannot resume: `Asked by <name> · <role> · ○ ended <time> · answer goes to <coordinator>`; Focus icon off, title "The pane is closed".
    - Ended, can resume (agent call, from R9): `Asked by <name> · <role> · ○ ended <time> · your answer resumes it`; Focus icon off.
    - Main coordinator ended and cannot resume (agent call): `… · ○ ended <time>`; the card stays open until Ryan answers or withdraws it.
    - Unknown: `The board does not know which session asked this.` and a link "Find the session" to `/sessions`. No tmux command at load.
    - Role: `main coordinator`, `epic coordinator`, `coordinator`, or `build under <coordinator>`. The name links to `/sessions/:id`.
    - This step ships the row component and its data; fm-zgd.17 places it in its new card layout. If fm-zgd.17 has not landed, the row replaces the "Source" line and "Go to session" button on today's card (agent call).
22. **Every source link goes to `/sessions/:id`** (user, charting). The card name link, the request drawer, the ticket panel Sessions tab (rows become: state badge, name link, role, last seen; the field dump moves to Details, audit A8; empty: `No sessions for this ticket.`) and the epic page session line. The Initiatives coordinator strip shows the shared badge, the name link and the Focus icon; its Relaunch and Start fresh move to the detail page (agent call, audit A6; see Open for Ryan).

### Tree (step 3)

23. **Nav and page** (user, fm-9mm.6). "Sessions" is the second nav item, after Needs you, with `hero-rectangle-stack` and no count badge. `/sessions` with `active={:sessions}` and the repos sidebar section, the same as Initiatives (agent call, audit B1). Header: `Sessions`, then the live line at the right.
24. **Layout: option C** (user). A "Waiting on you" strip of small cards, then one panel "All sessions" holding the tree as one-line rows: main coordinator, epic coordinators under it, builds under them, 28 px indent guides, collapse chevrons on coordinators, and an Unassigned group at the end for known sessions with no parent. Columns: name (kind chip on coordinators), ticket and branch (mono, one line, ellipsis, full text on hover), harness · model, state badge and second line, Focus icon (32 px). At 820 ticket and branch move to a second line and harness hides. The whole row opens `/sessions/:id`; the Focus icon sits above that link.
25. **Strip** (user). Shows every session whose label is Waiting on you, from the same state function as the tree, so a waiting session shows in both. At most 2 rows, then "Show all `<N>`". Each item starts with the verb: `Answer <N> cards` (links to the first card on Needs you), `Permission prompt · open the terminal` and `Usage limit · press Continue` (both link to the detail page). Second line: the time. Ended with an open card: `Answer 1 card · session ended`.
26. **Remembered per viewer** (user). Collapsed coordinators are stored in `localStorage` per coordinator id; reads and writes are wrapped so the page renders without storage. Show ended: a checkbox in the panel title, `Show ended (last 7 days) · <N>`; ended rows show in place, faded. Ended sessions leave the list 7 days after they end, except a dead session with an open card (R2), which stays (agent call). R8 rows: dead coordinator faded with "Its builds still run"; its live builds show `Parent ended <time>` with a warning icon.
27. **Updates** (agent call). The tree updates from the board's `:sessions_changed` broadcasts, which the session monitor sends on each tick that changes a row. The tree never runs `capture-pane`.

### Launch (step 4)

28. **Where** (user, fm-9mm.8). "Launch coordinator" on the epic row (Initiatives) and the epic page, for epics in idea, draft, ticketed, building or shipping. Done and abandoned epics show no control. No launcher on the Sessions page.
29. **One click, defaults, no form** (user, card e11bb1cd). Claude; the main coordinator's model (`--model` with the main coordinator row's `model`; no flag when that is null, agent call); the repo's main checkout; a fresh conversation. Other settings: start by hand.
30. **What it starts** (user). A window named by the epic id in the project's tmux session on `tmux -L foreman`; `agent_sessions` row with kind `epic_coordinator`, parent = the live main coordinator (none live: the most recent main coordinator row; none at all: no parent, so it shows under Unassigned, agent call), and `FOREMAN_SESSION` set to its name. Idea and draft epics keep today's `/tight-spec` prompt. Ticketed and later epics get a new `epic-coordinator` prompt template in the foreman skill's `session-launch` templates (fm-3c3.8): orient on the epic, run `dispatch` for its frontier in pane mode, close out under the usual rules, do not touch other epics.
31. **Control by state** (user, with agent call on labels). No session: Launch coordinator (`Launching…`). Live: Focus (one live session per name). Parked or ended: Resume (one click, the same as today's Relaunch) and the name link to the detail page, where Start fresh lives. Errors use today's launch error messages.

### Grid (step 5, after Tree and the detail page ship)

32. **Switch** (user, card 8a7f4f44). One Sessions page with a `Tree · Grid` switch next to the strip. Tree shows first; the board remembers the choice per viewer in `localStorage`. Both views use the same state function, Show ended checkbox and live line.
33. **Grid layout: option D** (user). One card per session, grouped by coordinator in a sunken region with the coordinator card first; builds in order waiting on you, working, in review, idle, ended. 4 columns at 1440, 2 at 820. Card: name, `main` or `epic` chip, Focus icon; state badge and second line; ticket chip and title; the last 6 lines of the pane, read-only. The border colour is the state. A dead pane shows `The terminal is closed` in place of the lines. The whole card opens the session.
34. **Grid reads** (user). Only cards on screen are read (the page tells the server which ids are visible), every 3 s for working and waiting cards and every 30 s for idle cards, never for dead ones, nothing while the tab is hidden. One tmux call per check for all visible panes, and a card is sent only when its hash changes. Claude panes drop their input box and status bar lines before the last 6 lines are taken.

### Copy for each screen

Copy follows ASD-STE100 and the house rules: labels, status, controls and instructions only. Some mockup lines that explained how the board works are cut here; this table wins over the mockups.

**Sessions page (Tree)**

| State | Copy |
|---|---|
| Success | Live line `Live · updated <time>` (green dot). Strip title `Waiting on you <N>`. Panel title `All sessions <N> · <N> working · <N> in review`. Unassigned group line: `The board knows these sessions but not the coordinator that started them.` |
| Empty | Dashed box. Title `No sessions are running`. Body `Coordinators and their builds show here while they run.` Primary button `Start main coordinator` (busy `Starting…`): resumes the last main coordinator conversation when there is one, else starts a fresh one, as today's Initiatives control does (agent call). No strip. |
| Empty, Show ended on | Same box, body `No sessions ended in the last 7 days.` |
| Loading | Live line `Connecting…` (grey dot). `Loading sessions…` above a skeleton panel of 5 indented rows. |
| Error: tmux does not answer | Live line `tmux does not answer · last read <time>` (amber dot). Banner: `Cannot read tmux. States can be out of date.` Button `Try again now` (busy `Trying…`). Every Focus icon off, title `tmux does not answer`. The tree stays readable. |
| Error: connection lost | Live line `Not connected · updated <time>`. Banner: `Not connected to the board. Trying again…` Button `Reload page`. The tree is faded and does not take clicks. |

**Session detail page**

| State | Badge · second line | Panel |
|---|---|---|
| Live line (all live states) | `Live · updated <time>`, last item of the meta row | |
| Working | Working · `Round <N> · output <time>` | **Working on round `<N>`.** Nothing waits on you. |
| Question | Waiting on you · `Question since <time>` | **It asked you a question.** `<question>` [Answer on the card] |
| Usage limit | Waiting on you · `Usage limit · resets <time>` | **Stopped at the `<provider>` usage limit.** The limit resets `<time>`. [Continue] and, for a Pi build with a fallback, [Resume on `<model>`] |
| Permission | Waiting on you · `Permission prompt · <time>` | **It waits for a permission answer in the terminal.** [Focus terminal] |
| In review | In review · `Round <N> report · <coordinator> reviews` | **`<coordinator>` reviews round `<N>`.** Nothing waits on you. |
| Idle | Idle · `for <time>` | **Idle.** Nothing waits on you. |
| Ended, can resume | Ended · `ended <time>` | **Ended `<time>`.** `<what ended it>`. [Resume] |
| Ended, cannot resume | Ended · `ended <time> · cannot resume` | **Ended `<time>` during round `<N>`.** This build cannot resume: `<reason>`. [Relaunch build on this ticket] |
| … and its coordinator ended (R8) | same | Extra line: `<coordinator> ended <time> too. Relaunch resumes <coordinator> first.` |
| Open card, cannot resume (R2, R9) | Waiting on you · `session ended <time> · cannot resume` | **Its question is still open.** `<question>` When you answer, your answer and the question go to `<coordinator>` as a note, and the card closes. [Answer on the card] [Relaunch build on this ticket] |
| Open card, can resume | Waiting on you · `session ended <time> · can resume` | Same title. `When you answer, the board resumes the session first.` |
| Parked coordinator | Parked · `parked <time>` | **Parked `<time>`.** Its builds keep running. [Resume] |
| Dead coordinator, cannot resume | Ended · `ended <time> · cannot resume` | **Ended `<time>`.** The board has no conversation id for it. [Start fresh] |
| Loading | header, controls and timeline come with the first render | Output panel: skeleton lines and `Reading the terminal…`; live line `Connecting…` |
| Error: tmux does not answer | last label, faded · `not checked since <time>` | **The board cannot reach tmux.** The session can still run. The label and output are from `<time>`. [Try again now]. Output head: `Cannot read the terminal: tmux does not answer.` Focus, Send message, Continue, Park and Stop are off with `tmux does not answer.` |
| Error: connection lost | last label | Live line `Not connected. Trying again…`; output panel dims |
| Empty timeline | | `No events yet.` |
| Empty output, live | | `No output yet.` |
| Empty output, dead | | `No output was saved for this session.` |
| Saved output head | | `Saved <time>, when the pane closed` / `Saved <time> from the last check` / `Saved <time>, when you pressed Stop` / `Saved <time>, when the session was parked` |
| Unknown id | | Breadcrumb only and `The board has no session with this id.` |

**Card source row**: Decision 21. **Epic row and page**: Decision 31; busy `Launching…`, `Focusing…`, `Resuming…`.

**Grid** (from the critique, with the same cuts): success as Tree, cards as Decision 33; empty and errors as Tree; loading is a skeleton of 3 groups of cards; tmux down fades the lines under the banner; connection lost fades the grid and it takes no clicks.

## Acceptance checks

1. **Identity, measured from outside the code.** Run the 2026-11-01 diagnosis query on cards created in the 7 days after step 1 ships. Baseline: about 72% broken at creation. Pass: every card from a board launch, `coord`, `foreman coordinator`, `pi-window` or relay session has an `agent_session_id`; zero build cards point at their coordinator's row; unknown sources come only from shells with no registered session.
2. A pane build launched by an epic coordinator in pane mode gets its own row: name = its `--name`, parent = the coordinator's row, `pane_id` = its `%N`, `conversation_id` = the Pi session id.
3. `foreman ask` from an unregistered shell is accepted, prints the warning, and its card shows the unknown row with no tmux command.
4. Every source link on a card, the drawer, the ticket Sessions tab and the epic page navigates to `/sessions/:id`; for a closed pane that page shows the dead view, never an error.
5. With a scratch tmux server: a live detail page shows output within 2 s of the agent printing it; no `capture-pane` runs for a pane no page shows (tmux command log).
6. Stop on a scratch build: the last output is saved, only that pane closes, the worktree and branch exist after, and the dead view offers Resume (id recorded) or Relaunch build (no id).
7. Park on a scratch epic coordinator with one pane build in its window: the coordinator's pane closes and the build pane keeps running (R11, R8).
8. Continue on a pane-mode build at a usage limit sends exactly `continue` and Enter to that pane, never to the coordinator pane (fm-3c3.9).
9. R9: a build with an open card stops and cannot resume; answering the card sends the parent coordinator a note with the question and the answer, and closes the card.
10. R8: Relaunch build on a dead build whose coordinator is dead resumes the coordinator first, then sends it the note.
11. The Sessions tree at 1440 with 15 sessions (5 waiting) shows all waiting sessions and at least 11 rows in the first view, matching mockup C.
12. Launch coordinator on a ticketed epic (scratch repo, stub `claude` printing argv and prompt) opens one window named by the epic id on `-L foreman` with the epic-coordinator prompt and the main coordinator's model; a second click focuses it; done and abandoned epics show no control.
13. Grid with 11 visible live cards makes at most one tmux process per 3 s (tmux command log); hiding the tab stops all reads.
14. No control label wraps or overflows at 1440 or 820 on the detail page (verify ui screenshots of every state).
15. The only state-colour mapping for sessions is the shared function (code search finds no other).

## Verification plan

Seams, highest first; these are the board's existing seams:

- **Machine tests** for every row of the Decision 7 table and rules R1 to R11, through the declared machine (the `Foreman.Fsm` test pattern the board uses for SessionMachine). The state function is a pure function with a table test for each label row.
- **Context tests** at the sessions context for writers, ask resolution (name, then pane, then unknown), Resume, Relaunch build, Start fresh, R8 and R9, against the test database.
- **tmux integration tests** on a temporary socket, as the launcher already does: capture, save on Stop and Park, close one pane only, Continue to a pane, Focus, the grid's one-call read.
- **CLI tests** for `foreman ask`, `foreman dispatch --name --pi-session`, `foreman session register --parent`.
- **LiveView tests** with element ids for the tree, strip, detail page states and controls, card source row, epic Launch control and the Tree · Grid switch.
- **Builder checks** before Decision 19's controls: the Pi and Claude model checks, run in a scratch worktree, results on the ticket (and a card for the Claude half).
- **verify ui** at 1440 and 820, light and dark, for every state in the copy tables, from a worktree preview, screenshots looked at.
- **Live probe** for acceptance check 1 after step 1 ships (read-only query on `foreman_dev`).
- `mix precommit` green in the build worktree.

## Ask-first boundaries

- Running migrations or writes against `foreman_dev` or the live board's tmux servers. Builds use worktree previews and scratch tmux sockets.
- Launching, stopping, parking or resuming a real coordinator or build during the build. Use scratch tickets and stub harnesses.
- Changes to `pi-window`, `coord`, the relay and the foreman skill templates beyond what Decisions 3 and 30 need (they live outside this repo).
- Adding any dependency (the ANSI converter is board code).
- Building the Claude "another model" control before Ryan answers the check card (Decision 19).
- Any text the board types into a pane other than Continue, Send message, notes and the relaunch note.
- Removing the Initiatives coordinator controls if Ryan says no to that item below.

## Left to the builder

- Module and function names, the machine's internal event names, and whether `waiting.*` are nested states or one state with a reason.
- How output activity is read per pane for working and idle, if it costs at most one tmux call per monitor tick plus the hooks and never runs `capture-pane` for the tree.
- The ANSI converter's internals, if it handles SGR (16, 256 and truecolor, mapped to theme tokens) and OSC 8 links.
- How the grid finds visible cards (an observer hook is expected) and how the detail page knows the output tab is shown.
- The exact Needs you anchor used by "Answer on the card".
- How a Pi resume is started (through `pi-window` or tmux directly), if Decision 20 holds.
- Slicing each step into tickets.

## Open for Ryan

1. **Initiatives coordinator controls.** Decision 22 moves Relaunch and Start fresh from the Initiatives strip to the main coordinator's detail page and leaves the badge, name link and Focus icon. Recommended: yes; the audit (A6) found all three buttons on with equal weight when the coordinator had ended. Asked on card 06a13e91.

Settled by the coordinator before approval (agent calls):

- **Note to all coordinators.** It is in the charting controls but no mockup places it. Decided: a secondary button `Note to all coordinators` in the Sessions page header that opens one text box with `Send note`; result `Sent to <N> coordinators.` and, when some were skipped, `Not sent to <names>: the pane is closed.`
- **Grid details the critique left open** (settle at the Grid ticket, step 5). Decided at the Grid ticket (step 5), starting from: keep Working cards on the base border with a 2 px `info` top edge, so only Waiting on you and In review get a full coloured border; show ended sessions as one-line chips at the end of their group; show the "Waiting on you" strip above the grid below 1100 px.
