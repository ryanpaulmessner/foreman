# Design pack: one layout for agent-written documents

Spec: `docs/specs/doc-layout.md` · Drawn at: foreman 5e80d09 · Legend: green = added, amber = changed, red = removed or frozen

## Data

No database change. The board keeps its stored brief and report paths (`sessions.details`, `agent_receipts`,
`stage_events`, `agent_notes`: about 700 rows into `~/dev/work`) as history.

**Files: one real ticket, now and proposed.** Support Board 2b slice 1 (work-8ec.22.1), from
`find ~/dev/work/slices` on 2026-11-06:

```text
NOW (15 files, 4 folders, 3 spellings of the slice)
slices/
├── support-board/
│   ├── 2b-01-grouping-prompt.md        brief
│   ├── 2b-01-fixes-r1.md … -r3.md      fix briefs
│   ├── msg-2b-01-r1.md … -r4.md        messages
│   ├── 2b.loop.md                      loop state (named for the phase, not the slice)
│   ├── reports/2b-01-grouping-r1.md … -r4.md
│   └── reviews/2b-01-grouping-r1.md
└── pr-bodies/sb-2b-grouping.md         PR body (third spelling)

PROPOSED (same 15 files, 1 folder, named by ticket)
builds/work-8ec.22.1/
├── brief.md   brief-r2.md   brief-r3.md   brief-r4.md
├── message-r1.md … message-r4.md
├── loop.md
├── report.md  report-r2.md  report-r3.md  report-r4.md
├── review.md
├── pr.md
└── evidence/          (git-ignored)
```

```mermaid
flowchart LR
  subgraph repo["Main checkout of the ticket's repo"]
    docs["docs/ (specs, adr, long-lived)"]
    builds["+ builds/TICKET/ fixed names"]:::added
    notes["~ notes/DATE-KIND-SLUG.md"]:::changed
    handoffs["handoffs/COORDINATOR.md"]
    tickets["tickets/ (unchanged)"]
    legacy["slices/ epics/ drafts/ proposals/ … frozen: edit only"]:::removed
  end
  classDef added fill:#d8f5d0,stroke:#2f7d32
  classDef changed fill:#fdecc8,stroke:#a86b00
  classDef removed fill:#f9d5d3,stroke:#b3261e
```

## State

Skipped: no state machine. `foreman check` and `foreman doc path` are stateless reads of the file tree and
`foreman.toml`.

## Flows

**1. Dispatch a build: the brief and report paths come from the CLI.**

```mermaid
sequenceDiagram
  participant C as Coordinator
  participant CLI as foreman doc path
  participant W as pi-window
  participant B as Builder (worktree or ReportSystem)
  participant R as Main checkout
  C->>CLI: brief work-8ec.22.1 --next
  CLI-->>C: ~/dev/work/builds/work-8ec.22.1/brief.md
  C->>R: write brief.md
  C->>W: launch --bead work-8ec.22.1 (no --report)
  W->>CLI: report work-8ec.22.1 --next
  CLI-->>W: …/builds/work-8ec.22.1/report.md
  W->>B: start pi with brief and report path
  B->>R: write report.md, evidence/ (absolute path)
  Note over B,R: nothing is written in the worktree, so no doc rides on the feature branch
```

**2. Commit: the pre-commit check refuses an invented name.**

```mermaid
sequenceDiagram
  participant A as Agent
  participant G as git commit
  participant K as foreman check
  A->>G: commit adds slices/support-board/2b-03-prompt.md
  G->>K: pre-commit hook
  K->>K: new file in a [docs] legacy folder
  K-->>G: exit 1 with error and command
  Note over K: "slices/ is frozen. Use: foreman doc path brief <ticket>"
  A->>G: commit adds builds/work-8ec.22.3/brief.md
  G->>K: pre-commit hook
  K-->>G: exit 0
```

**3. A note that belongs to no single ticket.**

```mermaid
sequenceDiagram
  participant C as Coordinator
  participant CLI as foreman doc path
  C->>CLI: note diagnostic zoho-timestamps
  CLI-->>C: ~/dev/work/notes/2026-11-06-diagnostic-zoho-timestamps.md
  C->>CLI: note weird-kind x
  CLI-->>C: error, allowed kinds research diagnostic audit update message check decision retro
```

**4. Old files: indexed once, not moved.**

```mermaid
sequenceDiagram
  participant C as Coordinator
  participant I as foreman doc index
  participant F as docs/legacy-index.csv
  C->>I: run in ~/dev/work
  I->>I: read each legacy file, guess kind from the name, ticket from Ticket or Foreman lines
  I->>F: path, kind, ticket, date, confidence
  Note over F: later clean-up joins on ticket, no file is renamed
```

## UI

Skipped: no board screen changes. The board's document list keeps showing `README.md`, `AGENTS.md` and
`docs/**/*.md`, so new specs still appear there; `builds/` is out of scope (spec non-goal).
