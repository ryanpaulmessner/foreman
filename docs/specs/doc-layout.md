# Spec: one layout for agent-written documents

Status: draft, decisions approved by Ryan 2026-11-06 in chat. Design pack: `doc-layout.design.md`.

## Goal

Every document an agent writes lands in a path that a rule decides, never a name the agent invents. The repos
keep producing as many documents as now, but each one can be found by ticket, kind and date with a
directory listing, and old documents can be sorted later without reading each one.

## What we found (2026-11-06)

- `~/dev/work` has about 5,350 files in ten doc folders (`slices/` 3,655, `epics/` 1,194, `notes/` 403, and
  others). There are about 2,800 text documents and 2,540 media files.
- Each document kind has 2 to 4 homes, and each home has several naming patterns. Build reports alone have about 6
  (`NN-rN.md`, `<feature>-NN-rN.md`, `sNN-<slug>-rN.md`, …). Only 1 file name has a ticket id.
- About 1,500 references between documents, 352 from tickets, 90 from handoffs, and about 700 rows in the board
  database point at these paths.
- Many documents are not in git: `epics/` 84 of 1,194, `notes/` 11 of 403, `drafts/` 0.
- Nothing checks documents. `foreman check` validates `tickets/` only.

## Decisions

1. **One layout in every foreman repo.** It is the same in the foreman, work, skills and dotfiles repos:

   | Path | Holds |
   | --- | --- |
   | `docs/*.md` | Long-lived repo documents (spec.md, design.md, known-issues.md) |
   | `docs/specs/<slug>.md`, `<slug>.design.md`, `<slug>/` | A project spec, its design pack, its mockups and audits |
   | `docs/adr/NNNN-<slug>.md` | Architecture decision records |
   | `docs/machines/<name>.md` | Generated machine docs (foreman only) |
   | `builds/<ticket-id>/` | All working documents for one ticket, with fixed names (decision 2) |
   | `notes/<YYYY-MM-DD>-<kind>-<slug>.md` | Documents that are not about one ticket |
   | `handoffs/<coordinator>.md` | A coordinator's standing handoff |

   `<slug>` is lowercase kebab-case, at most 40 characters. `<kind>` for notes is one of: `research`,
   `diagnostic`, `audit`, `update`, `message`, `check`, `decision`, `retro`.

2. **Fixed names inside `builds/<ticket-id>/`.** Round 1 has no suffix. Later rounds add `-r<N>`.

   | Name | Holds |
   | --- | --- |
   | `brief.md`, `brief-r2.md` … | The prompt a builder gets. A fix round is a brief with a later round number |
   | `message-r<N>.md` | A short follow-up sent to a running builder |
   | `report.md`, `report-r2.md` … | The builder's report for that round |
   | `review.md`, `review-r2.md` … | The coordinator's or reviewer's review of that round |
   | `loop.md` | Loop state (slice-loop) |
   | `pr.md` | The PR body |
   | `plan.md` | A build plan, when there is one |
   | `evidence/` | Screenshots, verify runs, logs. Any names inside |

   Documents about an epic, not one ticket, use the epic's id as `<ticket-id>`.

3. **Documents live in the main checkout of the ticket's repo.** This is the repo that holds `tickets/`, never a
   worktree or a code repo. A builder working in a worktree, or in ReportSystem for a work ticket, writes its
   report to that absolute path. Working documents therefore never ride along on a feature branch. The
   coordinator commits them with its ticket commits.

4. **Agents get paths from the CLI.** `foreman doc path <kind> <ticket-id>` prints the absolute path, and
   `--next` gives the next free round. `foreman doc path note <kind> <slug>` prints today's note path. Skills
   and scripts call it and never spell out a path.

5. **`foreman check` validates the layout on commit.** It already runs in each repo's pre-commit hook.
   - **Scope.** It checks `.md` and `.html` files that are added in the commit being made.
   - **Always allowed.** `README.md`, `AGENTS.md`, `CLAUDE.md` and `CHANGELOG.md` anywhere, plus paths that match
     the repo's `[docs] allow` globs in `foreman.toml` (for example `skills/**` in the skills repo).
   - **Legacy folders.** Folders listed in `[docs] legacy` can have existing files edited. A new file there is
     refused.
   - **Errors.** Each error names the file and prints the `foreman doc path` command that gives the right path.

6. **Old documents in `~/dev/work` are frozen, not moved.**
   - `slices/`, `epics/`, `drafts/`, `proposals/`, `research/`, `smells/`, `specs/`, `docs/` (raw data) and the
     loose `notes/*` files become `[docs] legacy`.
   - `epics/*/AGENTS.md` and `slices/_builder-rules.md` stay live and editable.
   - `foreman doc index` writes `docs/legacy-index.csv` once, with the columns path, guessed kind, guessed
     ticket, date and confidence.
     - The guessed ticket comes from `**Ticket:**`/`**Foreman:**` lines and `work-xxx` ids in the text.
     - The guessed kind comes from the name patterns in the survey.
   - Nothing is renamed, so no reference breaks.

7. **Foreman's own documents move to the layout.**
   - `docs/briefs/` (36) and `docs/sessions/` (36) are tracked. They move to `builds/<id>/brief.md` and
     `report.md`. `drafts/briefs/`, `drafts/sessions/` and `drafts/pr-bodies/` are untracked; they move to
     `brief*`, `report*`, `review*`, `pr.md` and `evidence/`.
   - Any old name that does not map to a ticket id goes to `notes/` or is listed for Ryan.
   - README and docs links are updated.
   - Board database rows keep their old paths as history. Nothing rewrites them.

8. **Text in git, evidence out.** Each repo's `.gitignore` gets `builds/*/evidence/`. Evidence stays in the
   repo's main checkout, so `review_ui` cards can read it. Text documents are committed.

9. **One place states the rule.** The `foreman` skill gets a "Documents" section: the table above,
   `foreman doc path` and the check. The other skills point to it. Each repo's `AGENTS.md` block written by
   `foreman adopt` gets one line pointing to it, plus the repo's own notes (legacy folders).

## Non-goals

- Moving or renaming the old `~/dev/work` documents (decision 6).
- Rewriting paths stored in the board database.
- Showing `builds/` on the board's document list or ticket page.
- A write-time Claude Code hook that blocks writes outside the layout (Ryan chose the commit check).
- Rules for code files, or for README files inside code folders.

## Acceptance checks

- [ ] `foreman doc path report fm-x` prints `<main checkout>/builds/fm-x/report.md` when run in a worktree of
      the repo, in another repo, and in a ReportSystem checkout for a `work-` ticket.
- [ ] `--next` returns `brief-r3.md` when `brief.md` and `brief-r2.md` exist.
- [ ] `foreman doc path note diagnostic zoho-timestamps` prints `notes/<today>-diagnostic-zoho-timestamps.md`.
      An unknown kind or a bad slug fails and lists the allowed kinds.
- [ ] Commit-time checks:
  - [ ] A commit that adds `slices/new-thing.md` in work fails `foreman check`, and the message names the right
        command.
  - [ ] A commit that edits an existing `slices/*.md` passes.
  - [ ] A commit that adds `builds/work-abc/notes.md` (not a fixed name) fails.
  - [ ] A commit that adds `builds/work-abc/report-r2.md` passes.
- [ ] `pi-window` with no `--report` uses the `foreman doc path report <first ticket>` path.
- [ ] Each of these names no path of its own and points to the foreman skill's Documents section: dispatch,
      slice-loop, pr, research, tight-spec, design-pack, to-tickets, wayfinder, handoff and code-review.
- [ ] Work repo: `foreman.toml` lists the legacy folders, `docs/legacy-index.csv` exists, and at least 80% of
      the rows for `slices/*/reports/*` have a guessed ticket.
- [ ] Foreman repo: `docs/briefs/`, `docs/sessions/` and `drafts/` are gone. Their files are under `builds/` or
      `notes/`. README links resolve. `foreman check` passes on the whole tree.

## Ask-first boundaries

- Any rename or move inside `~/dev/work`.
- Changing what the pre-commit hook does beyond `foreman check`.
- Installing the rebuilt CLI (chore card, as usual).
