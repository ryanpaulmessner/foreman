---
id: fm-49x
title: "This week: plain-words view of ReportSystem work and the weekly report"
type: epic
status: open
priority: 2
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-21
closed: null
close_reason: null
kind: internal
---

# This week: a plain-words view of recent ReportSystem work, and the weekly report

**Ticket:** none (foreman draft `draft:this-week`; wayfinder map `fm-xum`). Interview: Ryan, 2026-10-21.

## Goal

A new foreman page, **This week** (`/week`), shows in plain words all ReportSystem work from the current workweek and the work carried over from last week. From that page Ryan drafts, edits and marks as sent his Friday report to Arnoldo.

## Why

Ryan must keep up with everything that goes through the board, and he must be able to talk with confidence about what is being built into the app. That covers new features and also break-fix, mapping and access work. Today that means reading ticket files, PRs and review notes. He also writes the Friday report by hand from the same material.

Success for Ryan:
- He opens one page and in two minutes knows what moved this week, where each item is, and what each item does for users.
- On Friday, the report draft needs only light edits before he sends it.

## Non-goals

- **Only Ryan sees it.** No sharing, no auth, no page for Arnoldo.
- **The board never sends email.** "Mark as sent" only records that Ryan sent the report.
- **No AI call when the page or the draft is built.** All text comes from stored ticket content.
- **Only the `work` repo (ReportSystem) in version 1.** No foreman, skills or dotfiles tickets.
- **No Support Board (T-###) requests that have no foreman ticket.** No reads from the prod `tickets` schema.
- **No change to the Initiatives page or to Needs you.**
- **Failure even if it works:** the page shows an item as Shipped when it is not in production, or it hides an item that moved this week.

## Decisions

### Week and scope

1. (user) **Workweek:** Monday 00:00 to Sunday 23:59, US Central time.
2. (agent call) **Time zone setting:** add a board config key `board.timezone`, default `"America/Chicago"`, and a time zone database dependency. Today foreman has neither and uses UTC everywhere.
3. (user) **Scope:** tickets of the repo whose key is `work`.
   - (agent call) Make the repo a config key `board.week_repos`, default `["work"]`, so a later version can add repos without a code change.
4. (user) **Worked this week** means at least one activity in the week. Activity is any of these:
   - a `stage_events` row for the ticket, whatever its outcome
   - an `approval_requests` or `request_events` row for the ticket
   - a ticket-file date in the week: a `## Notes` line date, `closed`, or `parked`
   - (agent call) File dates have day precision only. A file date counts for the whole day in the board time zone.
5. (user) **Carried over** holds:
   - tickets with activity in the previous week that are not Shipped, Done or Closed, not done, and
   - tickets that are Shipped or Done now and are not in any sent report.

   Each carried item shows "carried N weeks".
   - (agent call) N counts consecutive earlier weeks, before this one, that have activity for the ticket. It uses today's state only. No past stage is stored or rebuilt.
   - (agent call) Activity before 2026-10-18 (when `stage_events` starts) comes from ticket-file dates only.
6. (user) **Reported items drop off.** An item that is in a sent report and is Shipped or Done does not show again. A "Closed, not done" item shows only in the week it closed.
   - If an item in a sent report is not Shipped and has activity again, it shows again: in this week's sections, or in Carried over if its only activity was last week.
   - (user) **Seed:** everything that was Shipped or closed by end of day Friday 2026-10-17 counts as reported. Week of 2026-10-13 is the first "previous week".

### Grouping and stages

7. (user) **Sections:**
   - by effective ticket kind (fm-c2w.29), in this order: Feature (grouped under each epic, epic title as a sub-heading), Break-fix, Mapping, Access, Internal, Unsorted
   - (agent call) a section with no items does not render
   - Carried over is its own section, above the kind sections, with the same inner grouping
8. (user) **Plain stages.** Each item has one plain stage, shown as a group inside its kind section:

   | Plain stage | When (first match wins, top to bottom) |
   |---|---|
   | Shipped | the PR's head commit is contained in `origin/production` |
   | Done | the ticket is closed and has no linked PR, and its close reason does not start with "won't do", "duplicate", "superseded" or "out of scope" (user) |
   | Closed, not done | the ticket is closed with one of those reasons, or its board stage is `abandoned` (user) |
   | On staging | the PR is merged and its head commit is contained in `origin/staging`, but not in production |
   | Waiting on you | a pending Needs you request exists for the ticket (push, open_pr, merge, decision, session_waiting) |
   | Waiting on others | the ticket is parked, or it has an open PR with no pending request |
   | Building | the board stage is dispatched, building, reported, in_review or committed |
   | Not started | anything else, for example a ticket that only got a note |

   The exact board stage, and the request id when there is one, show in the item's details.
9. (user + agent call) **Shipped detection.** Shipped means in production. ReportSystem deploys through a staging → production PR, plus hotfix PRs into production, and its PRs merge with merge commits.
   - (agent call) The board checks containment with the local git repo at the work repo's `code_path`, in a background job, never while a page or draft is built:
     - `git fetch origin production staging` every 10 minutes
     - `git merge-base --is-ancestor <head_sha> origin/<branch>` for each linked PR
   - (agent call) The fetch is read-only toward the remote. It never changes local branches or the working tree.
   - (agent call) A ticket with several PRs is Shipped only when all of its merged PRs are in production.
   - (agent call) A PR merged by squash would not be found. The page then shows On staging forever. To catch this, the details show "not found in staging" when a merged PR's head is in neither branch.
10. (agent call) **Keep PR history.** Today the sync sees only PRs that are open at sync time, and it keeps only the latest snapshot.
    - Add a table of ticket–PR links (repo, ticket id, PR number, URL, base branch, head SHA, state, first and last seen). The forge sync writes to it from now on, using the existing link rule.
    - The same background job also reads merged PRs from GitHub once per run, for the last 21 days, so a PR that opened and merged between two syncs is linked too.
    - A one-time backfill fills the table from the last 60 days of merged PRs.
    - The page reads only this table and the cached containment results. It makes no network call (see the ask-first list).

### Text

11. (user) **Item title:** the ticket title.
    - (agent call) If the ticket has a `## Summary` section that starts with a line `Title: <plain title>`, that line is the title on this page instead.
12. (user) **Plain-English summary.** The coordinator agent writes and updates a `## Summary` section in the ticket file at three points:
    - **when a build starts:** what it is and why
    - **when its PR opens:** what changed, what users will see
    - **at close:** the final state, what is left open

    Format (Markdown under `## Summary`):
    ```
    Title: <plain title, optional>
    What users see: <1–2 sentences>
    How it works: <2–3 plain sentences>
    Open or risky: <1 sentence or "Nothing open.">
    Report line: <one sentence for the weekly report>
    ```
    - The ticket projection extracts `## Summary` like `## Notes` and `## Acceptance`, and removes it from `description`.
    - Missing fields are allowed. The page shows what exists.
13. (user) **Expanded item details:**
    - the summary fields
    - board stage, kind, epic, last activity date
    - links: each PR (number and URL), the epic spec (`spec_link`), and the ticket file
    - any Markdown paths named in the ticket body that exist on disk (for example the prompt, the reviews and the report), shown as document links like Needs you cards do
14. (user, agent call: outside this build) **Coordinator skill changes.** The three summary writes become steps in the coordinator workflows so they happen without Ryan asking:
    - workspace skill `slice-loop`: at the first send, after the PR opens, and at close
    - house skill `dispatch`: at launch, after the PR opens, and at close-out
    - house skill `foreman`: the close instructions
    - A ticket in the work repo closed without a `## Summary` is a gap that the page shows as "no summary yet".
15. (user) **Backfill.** The coordinator writes `## Summary` for every work-repo ticket with activity since Monday 2026-10-13, before the page is first used. Ryan checks them on the page.
    - (agent call) Decisions 14 and 15 are coordinator work in the skills and workspace repos. They get their own tickets and are not part of the foreman PR. The foreman build only reads `## Summary`.

### Weekly report

15b. (user) **Which week.** The page opens on the current week and has back and forward arrows. If last week's report is not marked sent, a banner says so and opens last week's page and draft. There, MM/DD is last week's Friday.

16. (user) **Draft.** "Draft weekly report" builds text from stored data only:
    ```
    Subject: Ryan weekly update - MM/DD        (MM/DD = the Friday of the week)

    Key Accomplishments & Current Focus
    <per kind, Feature first, grouped by epic: one bullet per item that is Shipped, Done, On staging or Building this week, using its Report line (or its title when there is none), with a plain stage word in brackets>

    Upcoming Milestones
    <bullets: items Waiting on you or Waiting on others; the top ready ticket per Feature epic by priority (P0 first); epics whose target date is in the next 21 days, with the date>
    ```
    - (agent call) Each bullet is one line.
    - (agent call) Carried-over items appear in the same lists as this week's items.
17. (user) **Edit and save.** The draft shows in an editable text area. "Save" stores the text for that week. Building the draft again replaces the saved text only after Ryan confirms it. "Copy" copies the subject and body.
18. (user) **Mark as sent.**
    - It records the week, the time and the final text, and stamps each item that the draft was built from as reported, with its plain stage at that time.
    - It can be undone for that week.
19. (user) **Epic target date.** Epics get an optional frontmatter date `target` (ISO date).
    - Set with `foreman update <id> --target YYYY-MM-DD`.
    - Shown in the epic sub-heading on the page.
20. (agent call) **Storage.** One new table for weekly reports (key: week start date) and one for reported items (week start, repo key, ticket id, plain stage). Both are board data, not ticket files.

### Report state

| State | Event | Next state |
|---|---|---|
| none | draft | drafted |
| drafted | save | drafted |
| drafted | draft (confirmed) | drafted |
| drafted | mark_sent | sent |
| sent | undo_sent | drafted |
| sent | draft | sent (refused: undo first) |

## Acceptance checks

Run against the live board data unless noted.

1. **This week's list is complete.** For the week of 2026-10-20, every work ticket with a `stage_events` row, a request or a file date in the week appears on the page. Compare the list with a SQL count of distinct tickets from `stage_events` and `approval_requests` in the week, plus a grep of ticket file dates. Nothing is missing, and nothing outside the week shows.
2. **Shipped is true.** For each item shown as Shipped, `git merge-base --is-ancestor <head> origin/production` exits 0. For a PR merged to staging after the last staging → production PR (for example PR #373 after it merges), the page shows On staging, not Shipped.
3. **Carried over.** A ticket active in the week of 10/13 and not done shows under Carried over with "carried 1 week". With the 10/17 end-of-day seed, a ticket Shipped by then does not show.
4. **Mark as sent.** Draft, edit, save, mark as sent. Reload: the edited text is still there and the state is sent. Items that are both reported and Shipped are gone from the page. Undo restores them.
5. **Draft format.** The draft subject is `Ryan weekly update - 10/24` for the week of 10/20, and the two section headings match Decision 16 exactly.
6. **Summary text.** A ticket with a `## Summary` shows its fields in the details. Its `description` no longer contains the Summary heading. A ticket without one shows "no summary yet".
7. **Time zone.** A `stage_events` row at Monday 03:00 UTC (Sunday 22:00 Central) counts in the previous week.
8. **From outside the code:** desktop screenshots of `/week` in light and dark, with one item expanded and the report draft open.
9. `mix precommit` gives the same results as the base commit, except for the new tests.

## Verification plan

- **Test seams (fewest, highest):**
  - one pure module that takes tickets, events, requests, PR containment results, sent reports and a "now" in the board time zone, and returns the page model: sections, plain stages, carried-over counts and report bullets. Most tests go here, table-driven.
  - the git containment function, tested against a temporary git repo with a merge commit on staging and production
  - the ticket projection for `## Summary` and `target`
  - the CLI for `--target`
  - LiveView tests for `/week`: sections render, expand, draft, save, mark as sent, undo
- The report state machine is declared with the project's FSM pattern, with one test per state-table row.
- **Browser:** screenshots of `/week` on the live board after merge (acceptance check 8).

## Ask-first boundaries

- Any write to a remote: push, or a GitHub write. The fetch in Decision 9 is the only allowed remote access besides the existing GitHub reads.
- Any change to the Initiatives page, Needs you, or existing stages and events.
- Adding repos other than `work` to the page.
- Any AI or network call when the page or the draft is built.
- Changing ticket files other than through the added `## Summary` section and the `target` field.

## Left to the builder

- Table and module names, and the page layout within the existing Fluxon components and board styles.
- Whether containment results are cached in the DB or in memory. They must survive a page reload within the 10-minute window.
- How the epic sub-heading shows the target date and the "carried N weeks" label.
- Copy wording within plain English (ASD-STE100), except the exact strings in Decisions 16 and 18.
