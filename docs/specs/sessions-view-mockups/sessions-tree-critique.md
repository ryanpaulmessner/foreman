# Sessions tree page: critique of three options (fm-9mm.6)

Date: 2026-11-02. Mockup: `sessions-tree.html` (one file, variant, state and theme switcher at the top; open with `#v=C&s=live` and similar). Screenshots in this folder: `<variant>-<state>[-dark]-<width>.png`, states `live`, `ended`, `empty`, `loading`, `tmux`, `offline`, widths 1440 and 820.

How it was built: the board's compiled CSS (`/assets/css/app.css`) inlined, the real `Layouts.app` sidebar, the PR stack tree markup (`pull_requests_live.ex:440-460`), the Initiatives panel classes (`bb-initiative-panel`, `bb-section-title`, `bb-section-label`) and Fluxon badge and button class strings copied from rendered pages. A script checked that every class in the mockup exists in the CSS. New classes are named `bb-session-*` and use only theme tokens. Two icons that the board does not compile yet are added the same way Heroicons are compiled: `hero-rectangle-stack` and `hero-command-line` (also `hero-exclamation-triangle`, `hero-signal-slash`). Data is real: session names, tickets, branches and the pending card counts from `foreman_dev` and tmux on 2026-11-02, read-only.

Method: `ux-critique` (visual hierarchy, information density, affordance, heuristic evaluation), `ux-laws`, `ui-patterns` on screenshots of each option. Brand lens skipped: the repo has no `mood.md`, `voice.md` or `tokens.md`. One fix pass was made. "Fixed" below means fixed in the mockup and seen again in a new screenshot.

## What is the same in all three

- **Nav:** "Sessions" is second, after "Needs you", with `hero-rectangle-stack`, no count badge (audit B1). The Needs you badge stays the only count in the nav.
- **One state function** (audit B3): Working = `info`, In review = `warning`, Idle = neutral soft, Waiting on you = solid `primary` with `hero-inbox`, Ended and Parked = outline. Text is always in the badge.
- **Second line under the badge** says why or how long: "4 cards · 4 min", "Permission prompt · 2 min", "Usage limit · 22 min", "for 6 min", "ended 25 min ago". The card count is a link to the cards.
- **R2:** a dead build with an open card (`chat-why-alerts`) shows "Waiting on you" with "1 card · ended 20 min ago".
- **R8:** the dead coordinator `filter-design` stays in the tree, faded, with "Its builds still run". Its live build `filter-bar-production` shows "Parent ended 25 min ago" with a warning icon.
- **Unassigned** group at the end: sessions the board knows without a parent (`chief-research`, `demo-chat-insights`), with one line that says why they are there.
- **Ended filter:** a checkbox "Show ended (last 7 days) · 5". Ended rows show in place in the tree, faded, with the Focus icon disabled ("The terminal is closed").
- **Row actions:** Focus terminal icon (`hero-command-line`, 32 px target, disabled with a reason when the pane is gone or tmux is down) and open detail (the name, plus a chevron in A and B).
- **Live status** top right: "Live · Updated 2 s ago" with a green dot (audit A11).

## Option A: Stack cards (PR stack pattern)

Each session is a `bb-panel` card, indented 28 px per level with the elbow connector, as on Pull requests.

Strengths

- The closest copy of an existing board pattern (Jakob's law inside the product). People who use Pull requests read it at once.
- Each card has room for the ticket title, so you know what a build does without a hover.
- At 820 the card stacks cleanly: state and actions move to a bottom strip.

Findings fixed

- Depth-0 cards had an elbow connector with nothing above it. Removed for top-level rows. (Cosmetic, 1)
- The "build" chip repeated on every build, while the indent already says it. Removed; coordinators keep their kind chip. (Information density, 2)
- In the tmux error state, Focus icons stayed enabled while the banner said Focus does not work. Now disabled with the reason "tmux is not answering". (Heuristic 5, error prevention, 3; all options)
- The "Not connected" banner icon did not show (wrong colour class, `text-foreground-danger` is the text colour for solid danger). Now uses the `--danger` and `--warning` tokens. (Bug, 2; all options)

Findings left open

- **Height.** A card is about 110 px. 15 sessions make an 1,850 px page; at 1440 only 7 sessions are in the first view. Three of the five "Waiting on you" sessions are below the fold (serial position effect, information density). Severity 3.
- Five solid black badges in one list lower their pull (Von Restorff). Acceptable because they are the signal the page is for, but A has no other way to find them fast.

## Option B: Grouped panels (Initiatives pattern)

The main coordinator and each epic coordinator is a `bb-initiative-panel`. The coordinator is the panel header row (sunken background), its builds are rows in columns: Session, Ticket · branch, Harness · model, State, Actions. Epic panels sit inside a left rule under the main coordinator. Filter segments "All / Waiting on you 5 / Working 6 / In review 1" replace the header badges.

Strengths

- Common region: each coordinator and its builds are one box, so "whose build is this" needs no reading.
- Columns make scanning by one attribute easy (all states line up, all branches line up).
- The filter segments carry the counts and act on them (one control, not a count plus a filter).

Findings fixed

- The column header repeated in every panel (8 times). Now shown once at the top. (Information density, 2)
- At 820 the actions went to their own line under each row, so rows were 120 px tall. Now three columns at 820 (session, state, actions). (Composition, 2)
- The filter segments showed on the empty and loading states. Hidden there. (Heuristic 8, 1)
- "no ticket" showed twice on the Unassigned row at 820. Fixed. (1)

Findings left open

- **Nested boxes.** Panels inside a ruled column inside the page make three levels of containment. At 820 the ticket and branch chips stack in a narrow column and a build row is still about 120 px. Severity 2.
- Coordinators are both a "header" and a session with a state. The sunken header makes them look like labels, not things you can open (affordance). Severity 2.
- A coordinator with no builds (`ai-insights`) is a whole panel for one line. Severity 1.

## Option C: Outline with a "Waiting on you" strip (recommended)

A strip of small cards at the top lists only the sessions waiting on you, each saying what to do ("Answer 4 cards · 4 min", "Permission prompt · open the terminal", "Usage limit · press Continue"). Below, one `bb-initiative-panel` "All sessions" holds the whole tree as one-line rows (about 53 px) with 28 px indent guides and collapse chevrons on coordinators. Columns on the right: harness · model, state, Focus. The whole row opens the session.

Strengths

- **11 of 15 sessions show in the first view at 1440 (A shows 7)**, and the strip puts every "waiting on you" item first (serial position effect, Zeigarnik: open work is visible and resumable).
- The strip answers "what do I do now"; the tree answers "what is running and under whom". Two jobs, two places, and the strip is short (one line per item, not the full card; audit A9).
- One container, one row style: lowest visual noise of the three. Guides show the tree without a box per level (law of continuity).
- Whole-row link gives a large target (Fitts's law); Focus stays a separate 32 px icon above it.
- At 820, ticket and branch move to a mono second line and truncate; harness hides. The tree still fits in about 1.3 screens.

Findings fixed

- Harness and state columns did not line up (auto widths). Now fixed widths (140 px, 170 px; 150 px at 820). (Scanning pattern, 2)
- Branch names broke mid-word at 820. Now one line with an ellipsis; full name on hover. (Typography, 2)
- Indent was 20 px; now 28 px to match the PR stack (audit B4). (Consistency, 1)
- The Ended checkbox sat alone on its own row. Moved into the panel title bar. (Composition, 1)
- Strip cards said "4 cards to answer"; the label now starts with the verb and the time moved to the second line, so names do not wrap at 1440. (UX writing, 1)
- Only the name was a link (small target). Now the whole row opens the session. (Fitts, 2)
- Loading skeleton overflowed at 820. Fixed. (1)

Findings left open

- **Duplication.** A waiting session shows in the strip and in the tree. This is deliberate (the strip is the action list), but the build must keep both in step from one state function. Severity 1.
- The strip at 1440 with 5 items is one row; with 9 or more it becomes three rows and pushes the tree down. Proposal: cap at 2 rows and add "Show all 9". Severity 2, needs real-data testing.
- Collapse state is not remembered between visits. Proposal: remember per coordinator in `localStorage`. Severity 1.

## Recommendation

**Option C.** The page has two jobs: show what waits on you, and show the live tree. C is the only option that does both in the first view at 1440: all 5 waiting sessions and 11 of 15 tree rows. A is the most familiar but needs two screens of scrolling for 15 sessions. B groups well but adds boxes and still needs scrolling. C reuses the board's own panel, label and badge styles and the PR indent, so it is not a new look.

From A, C keeps the ticket title as a hover title only; if Ryan wants the title on the row, it fits as a second line at 1440 at the cost of about 10 px per row.

## Copy for each state (ui-patterns)

| State | When | Copy and behaviour |
| --- | --- | --- |
| Success (live) | socket up, tmux answers | Top right: "Live · Updated 2 s ago" (green dot). Strip title "Waiting on you" + count. Panel title "All sessions 15 · 6 working · 1 in review". Row second lines as listed above. |
| Empty | no live sessions and Show ended off | Dashed box. Title: "No sessions are running". Body: "Coordinators and their builds show here while they run. Start the main coordinator to begin." Button (primary, `phx-disable-with="Starting…"`): "Start main coordinator". Small text: "Ended sessions from the last 7 days show when you turn on Show ended." No strip, no filter. |
| Empty, Show ended on, nothing ended | | Same box, body: "No sessions ended in the last 7 days." (not built in the mockup) |
| Loading | first render before the socket connects | Top right: "Connecting…" (grey dot). "Loading sessions…" above a skeleton of the panel with 5 indented rows. Shimmer only when reduced motion is off. Expected under 1 s, so no spinner. |
| Error: tmux not answering | board up, `tmux` calls fail | Top right: "tmux not answering · last read 15:36" (amber dot). Banner (amber edge, warning icon): "Cannot read tmux, so states can be out of date" / "The board shows each session as it was at 15:36. Focus terminal does not work until tmux answers. The board tries again every 10 s." Button "Try again now" (`phx-disable-with="Trying…"`). The tree stays readable; every Focus icon is disabled with the title "tmux is not answering". |
| Error: board connection lost | LiveView socket down (`phx-disconnected`) | Top right: "Not connected · updated 15:38" (grey dot). Banner (red edge, signal-slash icon): "Not connected to the board. Trying again…" / "This list stopped updating at 15:38. It updates again when the connection comes back." Button "Reload page". The tree is faded (55%) and does not take clicks, so nobody acts on stale state. |
| Row: dead coordinator with live builds | R8 | Coordinator faded, "Ended" badge, "ended 25 min ago", note "Its builds still run". Build: normal, note "Parent ended 25 min ago" with a warning icon. |
| Row: ended with an open card | R2 | "Waiting on you" badge, second line "1 card · ended 20 min ago". Strip: "Answer 1 card · session ended". |
| Row: Focus not possible | dead or tmux down | Icon at 35% opacity, `aria-disabled`, title "The terminal is closed" or "tmux is not answering". |

## Not built in the mockup

- Filter by project. The sidebar project links go to Initiatives today; whether they filter Sessions is open.
- Keyboard: arrow keys to move through the tree, Enter to open, `f` to focus. Proposed, not drawn.
- Phone width: out of scope (map).

## Option D: All sessions grid

Asked for after C: one card per session, as in the asklog Chief Grid view (`~/dev/work/research/asklog-chief/analysis.md`, features 1, 3, 4, gap 1). Open with `#v=D&s=live`. Screenshots: `D-<state>[-dark]-<width>.png`, the same set as A to C.

Layout. Every session is a card in a 4-column grid at 1440 (2 columns at 820). A coordinator and its builds share one sunken group region, with the coordinator card first; groups pack into the grid by size (a group of 2 and a group of 2 share a row). In a group, builds go in this order: waiting on you, working, in review, idle, ended. Each card has 4 parts: the name, a "main" or "epic" chip on coordinators, and the Focus icon; the state badge with the same second line as A to C; the ticket chip and title; and the last 6 lines of the pane. The card border shows the state: solid `--primary` with a 1 px ring for Waiting on you, `--info` for Working, `--warning` for In review, the base border for Idle, and dashed for Ended and Parked. Filter chips above the grid ("All 15 · Waiting on you 5 · Working 6 · In review 1 · Idle 2") have a dot in the same colour as the border. The whole card opens the session; the card-count link and Focus sit above that link.

Terminal snapshot. The text is **example text** written for each session. The colour codes are real: `tmux capture-pane -e -p` on the coordinator panes on 2026-11-03 gave Pi truecolor (`38;2;167;152;215` bullets, `38;2;126;136;142` grey) and Claude Code 256-colour codes (`38;5;246` grey, `174`/`180` spinner, `220` auto mode, `153` paths, bold tool names). The mockup has its own ANSI-to-HTML function (fm-9mm.3). It reads SGR codes only and maps every colour to a theme token, so the text stays readable in light and dark: basic colours by name; 256-colour and truecolor to the nearest of red, yellow, green, blue or magenta (`--danger`, `--warning`, `--success`, `--info`, a mix of info and danger); greys to `--foreground-softer`; bold to `--foreground`. Background colours are dropped. A session whose pane is gone (ended, parked, or R2 `chat-why-alerts`) shows "The terminal is closed" in place of the snapshot.

Shared rules kept: nav, one state function, the second line under the badge, R2 (`chat-why-alerts` is Waiting on you with "1 card · ended 20 min ago" and a closed terminal), R8 (`filter-design` faded with "Its builds still run"; `filter-bar-production` with "Parent ended 25 min ago"), an Unassigned group with its one line, the Show ended checkbox, the Focus disabled rules, the live status top right, and the copy for each state. tmux down: snapshots fade to 45% under the banner. Offline: the whole grid fades and does not take clicks. Loading: a skeleton of 3 groups of cards.

Strengths

- **Shows what each session does now, with no click.** The last lines of the pane show "Allow this command?", "Usage limit reached" or "412 tests, 0 failures". Neither the tree nor the strip can show this (recognition over recall).
- **All 5 Waiting on you sessions and 11 of 15 sessions are in the first view at 1440**, the same count as C, and the snapshot shows the reason for each wait.
- The border colour is one cue across the whole page, and the chip dots use the same colours (law of similarity). The solid border and the solid badge make waiting cards stand out (Von Restorff).
- Group regions show "whose build is this" without indent guides (common region). Coordinator cards come first in their group (serial position).
- Big click targets: the whole card opens the session (Fitts).

Findings fixed (one pass, each seen again in a new screenshot)

- The page text showed mojibake ("Live Â· Updated") when the file was opened from disk, because the file had no charset. Added `<meta charset="utf-8">` at the top. This changes nothing in A to C, and the published page already had a charset. (Bug, 2)
- R2 `chat-why-alerts` showed an empty snapshot box. It now shows "The terminal is closed". (Heuristic 1, visibility of status, 3)
- With 7-line snapshots, `metric-defs-queries` (waiting) was cut off at the fold at 1440. Now 6 lines and tighter group padding, and all 5 waiting cards are in the first view. (Serial position, information density, 3)
- The "epic coordinator" chip cut names short ("support-boar…"). The chip now says "epic" or "main", with the full kind on hover. (Typography and hierarchy, 2)
- Builds kept the data order, so a waiting build could be last in its group. Builds now go waiting first, then working, in review, idle, ended. At 820 this brings `metric-defs-queries` into the first view. (Serial position, 2)
- The gap between groups was the same as the gap inside a group, so the groups did not read as groups. Now 16 px between groups and 6 px inside. The group region is a sunken background with no border: the weakest container that works, and only one nested box. (Proximity, common region, 2)

Findings left open

- **820 density.** The grid is 2 columns, so a group of 3 leaves one empty cell. 7 of 15 sessions are in the first view, and 2 of the 5 waiting sessions (`ai-chat`, `chat-why-alerts`) are below the fold. Page height: 2.2 screens at 820, 1.4 at 1440. The fix is one click, the "Waiting on you" chip. Another proposal: show C's strip above the grid below 1100 px. Severity 3.
- **Too many coloured borders.** 11 of 15 cards have a coloured border (5 waiting, 6 working), so colour does less to mark the waiting ones. Proposal: keep the Working border at the base colour with a 2 px `--info` top edge, and give a full coloured border to Waiting on you and In review only. Severity 2.
- **Depth is only one level.** Epic groups sit beside the main coordinator's group, not under it. The "epic" chip is the only sign of the main → epic link. A third level (a build that starts builds) has no place. Severity 2. The tree (C) shows depth; the grid does not try to.
- **The snapshot cuts long lines.** About 38 characters fit at 1440 and 34 at 820. Text after that is cut off, for example "resets 16:0". Lines are clipped, not wrapped, so the card height stays fixed. Proposal: show the full last line in a `title` on hover, and the full pane on the detail page. Severity 2.
- **Claude pane chrome.** The last lines of a Claude Code pane are the input box and the status bar (two rule lines, the prompt, "auto mode on · 3 shells"). If the build sends the raw last 6 lines, 4 of them are chrome. The capture must cut from the last pair of `─` rule lines, and this differs between harnesses (Pi has no input box). This is an implementation risk, not a layout one. Severity 2.
- **Show ended makes the grid longer.** Ended cards are full size with a closed-terminal box. The main coordinator's group grows to 2 rows (`pr-forge` alone on the second row). Proposal: show ended sessions as one-line chips at the end of their group. Severity 2.
- Branch, harness and model are not on the card (they are in A to C). They go to the detail page or a hover. Severity 1.
- Colour mapping drops backgrounds, so the green and red diff backgrounds in Claude edits (`48;5;22`, `48;5;28`) are lost. Severity 1.
- With tmux down, the snapshots fade but do not say how old they are; the banner gives the time. Severity 1.

First view (no scroll), live state, light: **1440: 11 of 15 sessions, 5 of 5 waiting** (C: 11 of 15 and 5 of 5; A: 7 of 15 and 2 of 5). **820: 7 of 15 sessions, 3 of 5 waiting.**

## Grid, tree, or both

**D alone.** D is best at "what is each session doing right now", which is the one thing Ryan opens tmux for today. It is worse at the other jobs. It shows only one level of the tree. It needs 2.2 screens at 820, and its cost grows with each session. With 25 sessions it is 3 screens at 1440. Without the strip, the waiting items are only the cards with a black border. I would not ship D alone.

**C alone.** C is still the best answer to "what waits on me" and "what runs under whom". It is cheap: it polls tmux for state, and it reads a pane only on the detail page (fm-9mm.3). Its weak point is the one D fixes: to see what a build is doing, you open it or Focus it.

**Both, as a Tree / Grid switch on one page (my view).** Chief has Tabs / Grid / Canvas for the same set of panes. Put a two-part switch "Tree · Grid" next to the filter chips, with Tree (C) as the default. Both views use the same filter chips, the same Show ended checkbox and the same state function. Remember the choice per viewer in `localStorage`. In Grid, keep C's "Waiting on you" strip at the top below 1100 px, so the 820 problem goes away. Build Grid second, after Tree and the detail page ship, because it adds the polling cost below.

**Cost.** fm-9mm.3 decided to poll only the pane being viewed, once a second. D in the first view at 1440 has 11 live snapshots; at that rate that is 11 `tmux capture-pane` processes a second, and it grows with each session. What D needs instead:

- Poll only cards that are on screen. A hook with an `IntersectionObserver` tells the LiveView which session ids are visible, and the server reads only those.
- Poll more slowly: every 3 s for Working and Waiting on you, every 30 s for Idle, never for Ended or Parked. Stop when the tab is hidden (`visibilitychange`).
- Make one tmux call per tick for all visible panes (several `capture-pane -p -e -S -12 -t <pane>` joined with `\;` in one `tmux` command). Then a tick is one process, not 11.
- Send a card only when its hash changes. Idle panes then send nothing.
- Keep the 1 s rate from fm-9mm.3 for the detail page only.

At these rates the grid costs about one tmux process every 3 s. That is close to what C already spends on state.
