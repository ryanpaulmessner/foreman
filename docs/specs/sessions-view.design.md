# Design pack: Sessions (live tree and session detail)

Spec: `docs/specs/sessions-view.md` · Drawn at: foreman 83066bb (Data, State); Flows and UI at b342fa8 (no `lib/` change since 83066bb) · Legend: green = added, amber = changed, red = removed

Parts and their sources: Data from "Session identity" (fm-9mm.1); State from the lifecycle statechart (fm-9mm.5); Flows from the controls and launch decisions (fm-9mm.7, fm-9mm.8); UI from the audit (fm-9mm.4), the tree (fm-9mm.6) and the detail page (fm-9mm.7).

## Data

### Now

from: migrations `20261018050131_add_stage_overlay`, `20261018171858_create_approval_requests`, `20261018230608_create_planning_sessions` (+ `20261019010353`, `20261019011939`); writers `Overlay.persist_effect({:record, :session}, …)` (overlay.ex:347), `SessionRegistry.register/1` (session_registry.ex:39), `Sessions.launch/2`; reader `RequestSource.for_request/2` (request_source.ex:8).

```mermaid
erDiagram
    sessions {
        bigint id PK
        text repo_key "ticket repo, or __foreman__ for a registration"
        text bead_id "ticket id, or registered"
        text window "dispatch: window name or %pane. registration: %pane"
        map details "session, harness, model, workdir, branch, base, brief, report, window"
        timestamp started_at
        timestamp last_seen_at
        timestamp ended_at
    }
    planning_sessions {
        uuid session_id PK "also the Claude conversation id"
        text project
        text ticket "coordinator, an epic, or draft:slug"
        text window "tmux window id on the board server, for example @38"
        text workdir
        text state "starting running waiting ended parked"
        array previous_windows
        timestamp launched_at
        timestamp last_activity_at
    }
    approval_requests {
        uuid id PK
        text repo_key
        text bead_id
        text kind
        text actor
        text session "free text from FOREMAN_SESSION, may be null"
        map facts
        text state
    }
    approval_requests }o..o| sessions : "matched at render time by details.session = session"
    approval_requests }o..o| planning_sessions : "matched only if session = session_id"
```

Facts on 2026-11-02 (read-only counts on `foreman_dev`):

| What | Count |
| --- | --- |
| `sessions` dispatch rows | 149 (4 open). 93 store a `%pane`, the rest a window name. 44 have no `details.session` |
| `sessions` registrations (`__foreman__/registered`) | 14 (9 open) |
| `planning_sessions` | 3 (1 ended, 2 parked) |
| `approval_requests` | 524. 101 have no `session` |

What is wrong in Now:

1. **No identity of its own.** A session is a name in a JSON field. A request points at it by text, matched again on every render. Nothing makes the name unique or correct.
2. **Dispatch stores the caller's name.** `foreman dispatch` copies `FOREMAN_SESSION` into `details.session`. When an epic coordinator dispatches a build, that is the coordinator's name, so the build row claims to be the coordinator (40 cards in the 2026-11-01 diagnosis).
3. **Coordinators only exist if someone registers them.** Launches outside the board (`coord`, relay windows) make no row until `foreman session register` runs by hand, and window names drift from session names (59 cards).
4. **Asks can have no session.** `foreman ask` sends `session = nil` when `FOREMAN_SESSION` is unset (101 requests).
5. **No parent, no conversation id for builds.** Nothing links a build to its coordinator, and Pi's session id is not stored, so a build cannot be resumed (fm-9mm.2).
6. **Two identity tables.** Board-launched coordinators live in `planning_sessions` with a UUID; everything else lives in `sessions` with a bigint and a name.

### Proposed

```mermaid
erDiagram
    agent_sessions {
        uuid id PK "+ the one identity. For Claude, also the conversation id"
        text name "+ unique among live sessions. Equals the tmux window name"
        text kind "+ main_coordinator, epic_coordinator, build"
        uuid parent_id FK "+ the coordinator that started it. Null for main"
        text harness "+ claude or pi (out of details)"
        text model "+"
        text conversation_id "+ Claude uuid or Pi session id, for Resume"
        text tmux_server "+ board or default"
        text pane_id "+ %N, always. Window name is display only"
        text project "+"
        text ticket "+ repo_key and bead_id of the ticket or epic, may be null"
        text workdir "+"
        text branch "+"
        text state "+ lifecycle, from the statechart ticket"
        timestamp started_at "+"
        timestamp last_seen_at "+"
        timestamp ended_at "+"
    }
    session_captures {
        uuid session_id FK "+ last pane output, for the dead view (fm-9mm.3)"
        text output "+ up to 200 lines with colour codes"
        text reason "+ exit, stop, park, poll"
        timestamp captured_at "+"
    }
    sessions {
        bigint id PK
        uuid agent_session_id FK "+ the build this dispatch started"
        map details "~ session key now means the build's own name. Caller goes to parent_id"
    }
    planning_sessions {
        uuid session_id PK "~ also agent_sessions.id, launch and park state stay here"
    }
    approval_requests {
        uuid id PK
        uuid agent_session_id FK "+ resolved when the ask is accepted, never at render"
        text session "~ kept for display and old rows"
    }
    agent_sessions ||--o{ agent_sessions : "parent of"
    agent_sessions ||--o| session_captures : "last output"
    agent_sessions ||--o{ sessions : "dispatch history"
    agent_sessions ||--o| planning_sessions : "coordinator launch state"
    agent_sessions ||--o{ approval_requests : "asked"
```

How each writer fills it:

| Who starts the session | Writes `agent_sessions` | Name | Parent |
| --- | --- | --- | --- |
| Board launch (main or epic coordinator) | `Sessions.launch/2`, same transaction as `planning_sessions` | the window name the board picks | main coordinator for epic coordinators |
| `coord` / `foreman coordinator` outside the board | `foreman session register` called by the launch script itself, with `$TMUX_PANE` | window name | as above |
| `pi-window` (window or pane build) | `foreman dispatch --name <build> --pi-session <uuid>`, from `pi-window` | the build window name, never `FOREMAN_SESSION` | the caller's `FOREMAN_SESSION`, resolved to its row |
| Relay / slice-loop build | the relay `open` step calls `foreman session register --parent <coordinator>` | relay window name | coordinator |

How an ask finds its session: the CLI always sends `FOREMAN_SESSION` **and** `$TMUX_PANE`. The server resolves by name first, then by live pane id. It stores `agent_session_id` on the request at that moment.

### Decisions (Ryan, 2026-11-02, fm-9mm.1)

- **D1 New table.** `agent_sessions` is the only identity; `planning_sessions`, dispatch `sessions` rows and requests point at it. A view over today's tables was rejected because it keeps the name matching.
- **D2 Accept and warn.** An ask resolves by name, then by `$TMUX_PANE`. If neither matches, the board accepts it, the card says "source unknown" and the agent gets a warning. Refusing was rejected because it stops a build mid-question.
- **D3 No backfill.** The 524 old requests keep their text name and show "source unknown" when it does not match. New identity applies from the migration on.
- **D4 Unique among live sessions.** A name can be reused after the old session ends; old cards still point at the old row by id and open its dead view.

| Migration | What it does | Reversible | Backfill | Rows |
| --- | --- | --- | --- | --- |
| create `agent_sessions` | new identity table, partial unique index on `name` where `ended_at is null` | yes (drop) | from the 14 registrations and 3 planning rows; dispatch rows only when they have a pane id and their own name | 17 + up to 93 |
| create `session_captures` | last output per session | yes | none | 0 |
| alter `sessions` add `agent_session_id` | link dispatch history to the build | yes | as above | ≤ 149 |
| alter `approval_requests` add `agent_session_id` | the card's source, fixed at ask time | yes | none (D3) | 0 |

## State

Ticket: "Session lifecycle statechart: states, events and the three user-facing labels" (fm-9mm.5). The Proposed tables below were model-checked with `/statechart` on 2026-11-02 (see Check). The full event table is spec Decision 7; this part keeps the states, labels, controls and rules, and the charts.

### Now

Three machines touch a session today. None of them covers a Pi build: a build has only a dispatch row and the ticket's stage.

- `Foreman.SessionMachine` (board-launched coordinators, `planning_sessions.state`). from: `docs/machines/session_machine.md`, generated by `mix foreman.fsm.docs` at 83066bb. States `new → starting → running ⇄ waiting → ended | parked`. `idle_timeout` parks a session only when `parkable?` (not the main coordinator); `window_gone` ends the main coordinator but parks the others; `relaunch` from `parked | ended` opens the same conversation again.
- `Foreman.ExternalSession` (registrations in `sessions`). from: `lib/foreman/external_session.ex`. Only `running → ended` on `pane_gone`, and `register` back to `running`.
- `Foreman.Stage` (the ticket, not the session). from: `docs/machines/stage.md`. `dispatched, building` = the build works; `reported, in_review` = the coordinator reviews it; `committed` and later = the build is finished.
- The card's own focus result (`WaitingCard`: `ready, unattached, window_gone, prompt_changed, prompt_busy, tmux_unavailable`) is where today's error boxes come from. from: `docs/machines/waiting_card.md`.

### Proposed

One new declared `Foreman.Fsm` machine for every `agent_sessions` row, with `kind` as a guard. "Live" means the pane exists. `Foreman.SessionMachine` stays for the launch and park bookkeeping on `planning_sessions` and fires the matching event here (spec Decision 7).

| State | Parent | Meaning | Comes from |
| --- | --- | --- | --- |
| `starting` | live | launched, no output yet | launch, register |
| `working` | live | output changed in the last 2 minutes | pane activity (monitor) |
| `idle` | live | no output change for 2 minutes, nothing pending | monitor |
| `waiting.question` | live | a pending card has this `agent_session_id` | `foreman ask` accepted |
| `waiting.permission` | live | the agent shows a permission prompt | `SessionWaiting` |
| `waiting.usage_limit` | live | the agent hit a usage limit | `SessionWaiting` |
| `parked` | dead | a coordinator closed by idle timeout or Park; can Relaunch | `idle_timeout`, Park |
| `ended` | dead | the pane is gone, or Stop | `exited`, `pane_gone`, Stop |

The label on the page comes from the state, plus the ticket stage for builds:

| Label | When |
| --- | --- |
| **waiting on you** | any `waiting.*` state. Wins over every other label |
| **in review** | a build that is `idle` and its ticket stage is `reported` or `in_review` |
| **working** | `starting` or `working` |
| idle | `idle` and not in review |
| ended / parked | dead states, with the time |

Controls by state:

| Control | Allowed in | Notes |
| --- | --- | --- |
| Focus terminal | every live state | |
| Send message | `idle`, `waiting.question` | typing into a working pane interrupts the agent |
| Answer | `waiting.question`, `waiting.permission` | opens the card or the inline answer |
| Continue | `waiting.usage_limit` | sends `continue` + Enter to that pane only (fm-3c3.9) |
| Park | coordinators, live | not the main coordinator |
| Stop | every live state | confirm names the session; the worktree is kept |
| Resume | `parked`, `ended` | Claude: conversation id exists. Pi: conversation id, worktree and session file exist (fm-9mm.2) |
| Relaunch build on this ticket | `ended` build without Resume | resumes the parent coordinator first if it is dead, then sends it the note (R8) |
| Resume on `<model>` | `waiting.usage_limit`, Pi build with a fallback pair | added at spec time (fm-9mm.7 note); stop, save capture, resume with `--model`. Claude half waits on a builder check |
| Start fresh | dead coordinator without Resume | new row, same name and parent; live builds move to it |

Rules for `/statechart` to check:

- R1 Every session has exactly one label at all times.
- R2 A pending card makes the session "waiting on you", whatever else is true.
- R3 A dead session never offers Focus, Send message, Continue, Park or Stop.
- R4 Resume shows only when its conditions above hold. Otherwise a dead build offers Relaunch, and a dead coordinator offers Start fresh.
- R5 Stop never deletes the worktree or the branch.
- R6 The main coordinator is never parked by idle timeout.
- R7 At most one live session has a given name.
- R8 *(Ryan, 2026-11-02)* When a coordinator ends, its live builds keep running and stay under it in the tree with a "parent ended" note. Relaunch build on a dead build first resumes its coordinator, then sends it the note.
- R9 *(Ryan, 2026-11-02)* When a session ends with a pending card, the card stays open and says the session ended. If the session can resume, answering resumes it first and then delivers the answer. If it cannot, the answer goes to its parent coordinator as a note with the question, and the card closes.
- R10 Every dead build has Resume, Relaunch build, or is closed out (ticket stage committed or later). Checked in the model; not written in the first draft of this list.
- R11 *(agent call at spec time, not model-checked)* Park and Stop close only the session's own pane, never its window. Today `SessionTmux.park/2` runs `kill-window` (session_tmux.ex:412-431), which would kill pane-mode builds in an epic coordinator's window and break R8. The model has no panes, so it cannot see this; the tmux integration test in the spec's Verification plan covers it.

### Check (statechart, 2026-11-02)

Model: one coordinator and one build it started (`Sessions.tla`, 1,792 states), plus one build alone for the chart (`Build.tla`, 51 states). Files and rerun: `/private/tmp/claude-504/-Users-ryanmessner-dev-work/445516f3-3607-44fe-9f1c-d5ce9debd526/scratchpad/statechart`, `~/.claude/skills/statechart/scripts/statechart Sessions.tla --config Sessions.cfg --view view.ts --out <new dir>` (and `Build.tla --config Build.cfg --view bview.ts`).

Rules that hold: R1, R3, R4, R5, R6, R10 (every dead build has Resume, Relaunch, or is committed). R3-R5 hold because the control table defines them that way; the check shows the table does not contradict itself, not that code will obey it. R7 (one live session per name) is not modelled: the model has one session of each kind.

Rules that break:

- **R2 breaks, fixed in the draft** (open card, ended session). Path: the coordinator asks a question → you press Stop → the session label says Ended while its card is still open. Fix applied in the chart below: an open card always makes the label "waiting on you", with "ended" as a second line.
- **R8 breaks** (Relaunch build with no live coordinator). Path: you stop the coordinator → you stop the build, which has no Pi session id → the dead build offers "Relaunch build", which sends a note to a coordinator that is not there. **Decided:** Relaunch build resumes the coordinator first (R8).
- **R9 breaks** (answer cannot be delivered). Path: the build asks → the build stops, and it cannot resume (no Pi session id, or close-out removed the worktree) → the card is open and its answer has nowhere to go. Today a ticket closing supersedes its pending cards, which covers the close-out case only. **Decided:** the answer goes to the parent coordinator as a note (R9).

Rendered report (chart, paths, rules): https://claude.ai/artifact/7Wqutsha9uYNtkox2JSaK3

Chart: one build session, with the R2 fix. Every state where a card is open after the session ended is marked; the R9 path is highlighted.

```mermaid
---
title: "Build session (proposed, with R2 fix: an open card always means waiting on you)"
---
stateDiagram-v2
  state "Legend" as legend {
    lg0: live
    lg1: dead
    lg2: Breaks R9_DeadCardCanBeAnswered
    lg3: Path to the R9_DeadCardCanBeAnswered bug
  }
  class lg0 teal
  class lg1 tan
  class lg2 breaks
  class lg3 bugPath
  s0: Working
  s1: Ended, no resume
  s2: Idle
  s3: Waiting on you
  s4: Ended, can resume
  s5: Ended, no resume, card open
  s6: In review
  s7: Ended, can resume, card open
  s8: Closed out
  s9: Closed out, card open
  [*] --> s0
  s0 --> s1: Stop, or the pane closes
  s0 --> s2: no output for 2 minutes
  s0 --> s3: permission prompt or usage limit or the agent asks
  s0 --> s4: Stop, or the pane closes
  s1 --> s0: you press Relaunch build
  s2 --> s0: output starts
  s2 --> s1: Stop, or the pane closes
  s3 --> s0: you answer or press Continue or you answer
  s3 --> s1: Stop, or the pane closes
  s3 --> s5: Stop, or the pane closes
  s0 --> s6: no output for 2 minutes
  s4 --> s0: you press Resume
  s2 --> s4: Stop, or the pane closes
  s3 --> s4: Stop, or the pane closes
  s3 --> s7: Stop, or the pane closes
  s5 --> s3: you press Relaunch build
  s0 --> s8: close-out ends it or Stop, or the pane closes
  s1 --> s8: the coordinator commits
  s6 --> s2: changes requested or the coordinator commits
  s6 --> s0: output starts
  s6 --> s1: Stop, or the pane closes
  s7 --> s0: you answer, the board resumes it first
  s6 --> s4: Stop, or the pane closes
  s2 --> s8: close-out ends it or Stop, or the pane closes
  s3 --> s8: close-out ends it or Stop, or the pane closes
  s3 --> s9: close-out ends it or Stop, or the pane closes
  s5 --> s9: the coordinator commits
  classDef breaks fill:#ffecee,stroke:#e72e3b,stroke-width:2.5px,color:#cd2834
  class s0 teal
  class s0 bugPath
  class s1 tan
  class s2 teal
  class s3 teal
  class s3 bugPath
  class s4 tan
  class s5 tan
  class s5 breaks
  class s5 bugPath
  class s6 teal
  class s7 tan
  class s8 tan
  class s9 tan
  class s9 breaks
```



### Proposed: coordinator session (hand-drawn from spec Decision 7)

Drawn by hand from the spec's state table, at the label level. The coordinator half of `Sessions.tla` checked these paths (R1, R3 to R8); this drawing adds Start fresh and pane-only Park and Stop (R11), which the model did not have. Green = new compared with `Foreman.SessionMachine` today.

```mermaid
---
title: "Coordinator session (proposed)"
---
stateDiagram-v2
  classDef added fill:#e7f6ec,stroke:#2f9e55,color:#1d6b38
  classDef changed fill:#fff4dc,stroke:#c98a00,color:#7a5300
  [*] --> starting: launch or register
  starting --> working: output changes
  working --> idle: no output for 2 minutes
  idle --> working: output changes
  working --> waiting: asks, permission prompt or usage limit
  idle --> waiting: asks, permission prompt or usage limit
  waiting --> working: answered, prompt cleared or output after Continue
  working --> parked: Park or idle timeout, not main
  idle --> parked: Park or idle timeout, not main
  working --> ended: Stop, or the pane closes
  idle --> ended: Stop, or the pane closes
  waiting --> ended: Stop, or the pane closes
  parked --> starting: Resume, same conversation
  ended --> starting: Resume, same conversation
  ended --> fresh: Start fresh, no conversation id
  fresh: new row, same name, builds move to it
  class idle added
  class waiting changed
  class fresh added
  class parked changed
```

Changes against today's `Foreman.SessionMachine` (session_machine.ex:26-91): `idle` is new (today `running` covers working and idle); `waiting` now has three reasons and a card from `foreman ask` enters it; Park is now a user control as well as the idle timeout, and closes the pane, not the window (R11); a window closed by hand ends the session here, where SessionMachine parks it; Start fresh makes a new row (D1: the id is the conversation id).

### Proposed: pane reader (hand-drawn, not model-checked)

The read-only output on the detail page (1 s) and the grid (3 s or 30 s) is a stateful job, so it sits on a declared machine (house rule). One instance per open page.

```mermaid
---
title: "Pane reader (proposed, one per open page)"
---
stateDiagram-v2
  classDef added fill:#e7f6ec,stroke:#2f9e55,color:#1d6b38
  [*] --> off
  off --> polling: page shows a live pane, or grid cards are on screen
  polling --> polling: tick, send only when the hash changes
  polling --> paused: tab hidden, or output tab not shown
  paused --> polling: tab shown again
  polling --> tmux_error: capture fails
  tmux_error --> polling: retry succeeds, or Try again now
  polling --> off: pane gone, or page closed
  paused --> off: page closed
  tmux_error --> off: page closed
  class off added
  class polling added
  class paused added
  class tmux_error added
```

Guards: the detail page reads one pane at 1 s; the grid reads only visible cards, 3 s for working and waiting, 30 s for idle, never dead ones, in one tmux call per tick. Events come from the page hook (visible ids, `visibilitychange`) and from the tick result.

## Flows

### Now

from: `needs_you_live.ex:138-148` (`resolve/1` for `go-session`), `request_source.ex:8-60` (`for_request/2`, `focus/2`), `request_context.ex:47-105` (source line, button, copy box); launch from `planning_session.ex:4-30`, `sessions.ex:170-241`, `session_tmux.ex:369-391` and `:480-500`.

Go to session today. The card learns the link is broken only after the click.

```mermaid
sequenceDiagram
  actor Ryan
  participant Card as Needs you card
  participant LV as NeedsYouLive
  participant RS as RequestSource
  participant DB as Postgres
  participant T as tmux
  Ryan->>Card: click Go to session
  Card->>LV: go-session event
  LV->>RS: for_request(request)
  RS->>DB: sessions where details.session equals request.session
  alt no row and no live tmux name
    RS-->>LV: nil
    LV-->>Card: source unknown, raw tmux command to copy
  else row found
    RS->>T: list-panes -a, then select the pane
    alt window closed or no client
      T-->>RS: error
      RS-->>LV: WaitingCard window_gone or unattached
      LV-->>Card: The session window is closed, or copy box
    else
      T-->>Ryan: terminal shows the pane
    end
  end
```

Launch today: only idea and draft epics and unplanned tickets are launchable (`sessions.ex:170-175`); no `--model` flag is passed (`session_tmux.ex:480-500`); the window is named by the ticket id on `-L foreman`; no row records a parent.

### Proposed

Every state event named in the spec appears below. Machine events are written as "AgentSession: event". New tables: `agent_sessions` is written in flows 1 and 3 and read in all; `session_captures` is written in flow 4 and read in flow 2.

**1. A build asks a question (identity, D2).**

```mermaid
sequenceDiagram
  participant B as Pi build pane
  participant CLI as foreman ask
  participant API as Board agent API
  participant Ctx as Sessions context
  participant DB as Postgres
  B->>CLI: foreman ask, with FOREMAN_SESSION and TMUX_PANE
  CLI->>API: ask request with name and pane
  API->>Ctx: resolve source
  Ctx->>DB: live agent_sessions by name
  alt no name match
    Ctx->>DB: live agent_sessions by pane id
  end
  alt match
    Ctx->>DB: insert approval_request with agent_session_id
    Ctx->>DB: AgentSession: asked, state waiting.question
  else no match
    Ctx->>DB: insert approval_request, agent_session_id null
    API-->>CLI: accepted with warning
    CLI-->>B: The board does not know this session
  end
```

**2. Open a session from a card (live or dead).**

```mermaid
sequenceDiagram
  actor Ryan
  participant Card as Card source row
  participant D as SessionLive detail
  participant Ctx as Sessions context
  participant R as Pane reader
  participant T as tmux
  participant DB as Postgres
  Note over Card: row already says live or ended, before the click
  Ryan->>Card: click the session name
  Card->>D: navigate to /sessions/id
  D->>Ctx: get session, timeline, open cards
  Ctx->>DB: agent_sessions, events, requests by agent_session_id
  D->>D: state function gives label, second line, controls
  alt pane is live
    D->>R: viewer_on
    loop every 1 s while shown
      R->>T: capture-pane -p -e -J -S -200 on this pane
      R-->>D: push only when the hash changes
    end
  else pane is gone
    D->>DB: last session_captures row
    D-->>Ryan: dead view, saved output, Resume or Relaunch build
  end
```

**3. One-click launch of an epic coordinator.**

```mermaid
sequenceDiagram
  actor Ryan
  participant E as Epic row or epic page
  participant Ctx as Sessions context
  participant DB as Postgres
  participant T as tmux -L foreman
  Ryan->>E: Launch coordinator
  E->>Ctx: launch epic
  Ctx->>DB: live agent_sessions with name equal to the epic id
  alt a live coordinator exists
    Ctx->>T: focus its pane
    Ctx-->>E: button reads Focus
  else none live
    Ctx->>DB: main coordinator row, for parent and model
    Ctx->>DB: insert planning_sessions and agent_sessions in one transaction
    Ctx->>DB: AgentSession: launch, state starting
    Ctx->>T: new-window named by the epic id, claude with session-id and the main model
    T-->>Ctx: window id and pane id
    Ctx->>DB: save pane_id
    Ctx-->>E: button reads Focus, name links to the session page
  end
  Note over T: epic coordinator dispatches builds in pane mode, each registers with parent set to it
```

**4. Stop, then Resume or Relaunch build (R5, R8, R11).**

```mermaid
sequenceDiagram
  actor Ryan
  participant D as Detail page
  participant Ctx as Sessions context
  participant T as tmux
  participant DB as Postgres
  participant C as Parent coordinator
  Ryan->>D: Stop, then Stop session in the in-page confirm
  D->>Ctx: stop
  Ctx->>T: capture-pane on this pane
  Ctx->>DB: session_captures, reason stop
  Ctx->>T: kill-pane on this pane only
  Ctx->>DB: AgentSession: stop, state ended
  Note over T: worktree and branch stay, other panes in the window keep running
  alt resumable
    Ryan->>D: Resume
    Ctx->>T: open pane, pi session-id or claude resume
    Ctx->>DB: AgentSession: resume, state starting, new pane_id
  else build not resumable
    Ryan->>D: Relaunch build on this ticket
    opt parent is dead
      Ctx->>T: resume the parent conversation
      Ctx->>DB: AgentSession: resume on the parent
    end
    Ctx->>C: note, relaunch the build for the ticket on the branch
    Note over DB: the dead row stays ended, the new build registers its own row
  end
  alt Ctx call fails
    Ctx-->>D: Could not stop the session, reason, nothing changed
  end
```

**5. Usage limit: Continue, or resume on another model (Pi build).**

```mermaid
sequenceDiagram
  actor Ryan
  participant C as Coordinator
  participant Ctx as Sessions context
  participant D as Detail page
  participant T as tmux
  participant DB as Postgres
  C->>Ctx: pi-wait exits LIMITED, session_waiting for the build row
  Ctx->>DB: AgentSession: usage_limit, request with provider and reset time
  D-->>Ryan: Waiting on you, resets at a time, Continue and Resume on a model
  alt Continue
    Ryan->>D: Continue
    Ctx->>T: send-keys continue and Enter to the build pane only
    Note over Ctx: AgentSession: continue, state stays until output changes
    T-->>Ctx: output changes
    Ctx->>DB: AgentSession: output_changed, state working, clear request
  else Resume on another model
    Ryan->>D: Resume on the fallback model
    Ctx->>T: capture, then stop the Pi process
    Ctx->>DB: session_captures, reason stop
    Ctx->>T: pi with the same session-id and the new model, in its worktree
    Ctx->>DB: AgentSession: resume_on_model, state starting, model changed
  end
```

**6. Answer a card whose session ended (R9).**

```mermaid
sequenceDiagram
  actor Ryan
  participant N as Needs you
  participant Ctx as Sessions context
  participant DB as Postgres
  participant T as tmux
  participant C as Parent coordinator
  Ryan->>N: answer the card
  N->>Ctx: deliver the answer
  Ctx->>DB: agent_sessions row for the card
  alt session is live
    Ctx->>T: deliver to the pane, as today
  else dead and resumable
    Ctx->>T: resume the session
    Ctx->>DB: AgentSession: resume
    Ctx->>T: deliver the answer
  else dead and not resumable
    Ctx->>C: note with the question and the answer
    Ctx->>DB: close the card
  end
  Ctx->>DB: AgentSession: last_card_closed when no card is open
```

**7. The tree and grid stay current.**

```mermaid
sequenceDiagram
  participant M as SessionMonitor, every 3 s
  participant T as tmux
  participant Ctx as Sessions context
  participant DB as Postgres
  participant P as Sessions page
  M->>T: one list-panes call for live panes and activity
  M->>Ctx: reconcile
  Ctx->>DB: AgentSession: output_changed, quiet, pane_gone, exited
  Ctx-->>P: sessions_changed broadcast
  P->>P: state function, re-render strip and tree
  opt Grid view
    P->>Ctx: visible card ids from the page hook
    Ctx->>T: one tmux call with capture-pane for each visible live pane
    Ctx-->>P: changed cards only
  end
  alt tmux does not answer
    Ctx-->>P: tmux error, last read time
  end
```

## UI

### Now

from: the audit `docs/specs/sessions-view-audit/ux-audit.md` (fm-9mm.4), live board at 1440 and 820, with file:line for each finding. In short:

- Go to session is a button that fails after the click (`request_context.ex:54-105`); the session shows three times on a card (`request_context.ex:47-53`, `needs_you_live.ex:970`); "Source unknown" shows a raw tmux command at load; "This session has ended." has no time and no next step (`request_context.ex:65-71`).
- Five copy-command patterns, none says Copied (A5).
- Initiatives coordinator strip: raw state atom, Focus on after the session ended, three equal buttons (`initiatives_live.ex:362-410`).
- Ticket panel Sessions tab is a field dump (`ticket_detail.ex:464-485`).
- Three state-colour maps (`initiatives_live.ex:313`, `epic_live.ex:335`, `ticket_detail.ex:251`).
- No page for sessions and no "not connected" signal (`layouts.ex:180-195`).

### Mockups (built from the board's compiled CSS and markup, critiqued)

| Mockup | What it shows | Pick |
|---|---|---|
| Sessions tree, `sessions-view-mockups/sessions-tree.html`, published https://claude.ai/artifact/4UCbQNQ3NG55L29M7cJ8WD | options A stack cards, B grouped panels, C outline with a Waiting strip, D all-sessions grid; states live, ended, empty, loading, tmux down, offline; 1440 and 820; light and dark | **C** (Tree, ships first) and **D** (Grid, behind a Tree · Grid switch, ships last). fm-9mm.6 |
| Session detail, `sessions-view-mockups/session-detail.html`, published https://claude.ai/artifact/3tu2g2ucMsvuV3UdcpcWMG | options A workbench, B next step first, C console, and the card source row before and after; 9 states | **B with A's round grouping**. fm-9mm.7 |
| Card source row, `sd-card-source-row-1440.png`, `-820.png` | one "Asked by" row replacing the Source line and Go to session | live or ended, no state badge (fm-zgd.17 card 86cedfd3) |

Critiques: `sessions-view-mockups/sessions-tree-critique.md`, `sessions-view-mockups/session-detail-critique.md` (ux-critique, ux-laws, ui-patterns, one fix pass each). Screenshots per option and state sit beside them.

### Changed screens and their states

The exact copy for every state is in the spec (Decisions 17, 21, 31 and "Copy for each screen"). The spec's copy wins over the mockups: lines that described how the board works were cut (house rule), and clock times became the shared relative format.

| Screen | Empty | Loading | Partial | Error | Success |
|---|---|---|---|---|---|
| Sessions, Tree | `No sessions are running` + Start main coordinator; Show ended on: `No sessions ended in the last 7 days.` | `Connecting…`, `Loading sessions…`, 5-row skeleton | strip capped at 2 rows + `Show all <N>`; collapsed coordinators; R8 rows | tmux down banner + Try again now, Focus off; connection lost banner + Reload page, tree faded | strip + `All sessions <N> · <N> working · <N> in review`, `Live · updated <time>` |
| Sessions, Grid | as Tree | 3 groups of skeleton cards | dead cards show `The terminal is closed` | tmux down: lines faded under the banner; offline: grid faded | cards with border = state and last 6 lines |
| Session detail | `No events yet.` / `No output yet.` / `No output was saved for this session.` | output skeleton + `Reading the terminal…` | off controls in one `Not available now:` line | tmux down panel, label faded, controls off with reason; connection lost; unknown id `The board has no session with this id.` | next-step panel with one filled button, result line after each control |
| Card source row | unknown: `The board does not know which session asked this.` + Find the session | (server render) | ended: `○ ended <time> · answer goes to <coordinator>` or `· your answer resumes it` | | `Asked by <name> · <role> · ● live` + Focus icon |
| Epic row and epic page | no session: Launch coordinator | `Launching…` | parked or ended: Resume + name link | today's launch error messages | live: Focus + name link |
| Ticket panel Sessions tab | `No sessions for this ticket.` | | | | rows: badge, name link, role, last seen |
| Initiatives coordinator strip | `Not started` | | | | badge, name link, Focus icon (see spec Open for Ryan 1) |

### Critique findings left open

- Tree: duplication of waiting sessions in strip and tree is deliberate; both come from one state function (spec Decision 25).
- Detail: the tmux-down label can look current (finding 1): spec fades it and adds `not checked since <time>`. Timeline icons at 10 px (finding 4) and the black open-card dot (finding 5): left to the builder within the board tokens.
- Detail: Continue before the reset (finding 2): decided, Continue stays on and the page shows the reset time; fallback model control added (spec Decision 19).
- Grid: 820 density, too many coloured borders, ended cards full size, one level of depth, cut lines, Claude pane chrome, lost diff backgrounds. Border, ended chips and the strip below 1100 px are in the spec's Open for Ryan 3; pane chrome is spec Decision 34; the rest stay as known limits of the Grid.
- Nav: Sessions second with no count (audit B1), kept in all options.
