# foreman MVP: spec

Status: approved 2026-10-17; mockup approved the same day. Design detail and rationale live in `docs/design.md` (the design pass); the mockup's source is in `docs/mockup/` (live: https://claude.ai/artifact/BwE6JCfLAQMnSgdEDSSdNg). Where this spec and the design disagree, this spec wins.

## Goal

A local web board organised around epics (major features and initiatives) that shows each epic's stage from idea to shipped, the planned tickets and fallout under it, the few orphan one-offs, and each project's open change requests, kept current by agents through the house skills.

## Why

The user's work is driven by epics: a feature set or initiative drives all the planned work under it, plus the fallout found along the way; orphan bug fixes exist but are the exception. They want to see where each initiative stands without being inside a coding session: which are still ideas or specs, which are being built, what each ticket under them is doing, and what PR stack is open per project. Agents (Claude Code coordinator, pi build sessions) keep it current as a side effect of the workflow they already follow, so the board can be trusted at a glance. Success: after a normal day of speccing, dispatching and merging, the board matches reality without anyone updating it by hand.

## Non-goals

- Writing to beads in any form (create, update, close, notes, labels). Beads is read-only; the board suggests `bd` commands, it never runs them. Two-way sync is a later project; the MVP only keeps the path open.
- Adding any file, hook or field to the beads repos. A board that needs repo cruft has failed even if it works.
- Editing ticket content in the UI. It is a dashboard plus a merge action.
- Launching, steering or killing pi/tmux sessions; touching worktrees or running local git.
- Forge adapters other than GitHub; creating PRs; squash or rebase merges; reviewing diffs; deleting branches.
- Starting Dolt servers or migrating repos out of server mode.
- Multi-user, remote hosting, auth beyond a local token.

## Decisions

1. **Stack** (agent call, from design): Phoenix 1.8 + LiveView 1.1, Oban on Postgres 16, the same versions gw2 pins; bound to 127.0.0.1 only. Runs as one release under two user systemd units (user), foreman-web (endpoint) and foreman-worker (Oban queues, beads reader and scheduler, config watcher), selected by a role setting, with Restart=always, so it is up whenever agents are and nothing lives in a tmux window. Broadcasts the views depend on cross the two nodes through Postgres (no Erlang clustering). Postgres stays the host's own service. Containers were considered and set aside: the reader needs host repos, the host bd, /proc/locks matching and host credentials.
2. **Fluxon UI** (user): Fluxon's components and default theme (light and dark). The license is read from environment variables set in the untracked shell-local file; nothing that identifies the license material enters the repo, and `mix precommit` checks for it.
3. **Where data lives** (user: Postgres for all of the app's storage, no flat files, SQLite only if unavoidable, which it is not): a field lives with its writer. Beads owns ticket content (read through `bd export`, projected into droppable tables). Postgres owns every process fact beads does not know (stages, events, sessions, agent notes, change-request links, merge audit, draft epics) and the CLI's offline queue (a spooled-events table the CLI writes directly when the web app is down; Postgres runs as a service independent of the app). The only non-database files are the hand-edited TOML config (settings, not data) and the API token, which is a secret and lives with the other secrets under `~/.ssh`.
4. **Config file** (agent call, user floated): one global `foreman.toml` under the user's config dir, kept in dotfiles with home-relative paths, plus an untracked local override file; defaults ship in the app. It lists repos (path, forge, forge repo, colour, enabled), board columns as groups of stages, backfill defaults, swimlane default, stale-session threshold, per-epic display options. It may name stages, never define them: unknown stage names are a load error. Hot reload on change; a bad edit keeps the last good config and shows the error. No per-repo config file.
5. **Reading beads** (agent call; failure rule is the user's): one `bd export` per repo per sync; change noticed by polling cheap file signals every few seconds, pings from the `foreman` CLI, and a 5-minute sweep; an unchanged export hash is a no-op. A repo whose store cannot be opened (we_go_next_dev today) shows as unreachable, never blocks the others. Unknown bd statuses or types render as grey badges, never crash. **The board is failure tolerant and never interrupts an agent's `bd` write** (user): a failed or contended read is retried later and never surfaced as an error to agents; if the concurrency probe (first ticket) shows reads can break writes, the reader skips while a write is visible or reads less often, and the freshness target relaxes from 5 s to 30 s. The store is never copied or written by the board.
6. **State-machine DSL** (user): every stateful feature is a machine declared with a house Elixir macro DSL, as function-call-style declarations (`initial`, `state`, `group`, `event`, `guard`, `effects`, `transition`, `ignore`, `invalid`). Compile-time errors for: undeclared names, missing or duplicate `initial`, guards without a function, uncovered (state, event) pairs, all-guarded pairs, duplicate rows, dead rows, unreachable states, effects on ignore/invalid rows, and (per machine option) observed events declared invalid. `step/3` is pure and total, returns `{next_state, effects}` with effects as data, or `{:error, {:invalid, state, event}}`. Mermaid diagram and full matrix are generated and held to a committed golden file. `:gen_statem` only for a machine that needs timeouts; none in the MVP. Lives in this repo until a second Elixir repo needs it.
7. **Ticket stage machine** (agent call, from design): states and events as below. Claimed events come from agents or the UI and are refused when out of order (the API answers with the current stage and the allowed events); observed events are facts from beads or the forge and are never refused.

   | From | Event | To | Effects |
   |---|---|---|---|
   | queued | dispatch (claimed) | dispatched | record session |
   | dispatched, building | dispatch [new session] | dispatched | record session, note re-dispatch |
   | dispatched, building | progress | building | append progress |
   | reported .. merged | progress | stay | append progress |
   | dispatched, building | report | reported | record report |
   | reported | review | in_review | |
   | in_review | request_changes | building | append finding |
   | in_review | commit | committed | record commit |
   | committed | commit | stay | record commit |
   | any live stage | abandon | abandoned | |
   | abandoned | revive | queued | |
   | queued .. committed | cr_opened (observed) | pr_open | link change request |
   | pr_open, merged | cr_opened | stay | link |
   | pr_open | cr_closed [another open CR] | stay | unlink |
   | pr_open | cr_closed | committed | unlink |
   | pr_open | cr_merged | merged | record merge; on entering merged, suggest the `bd close` |
   | pr_open | bead_closed | done | flag "closed with open CR" |
   | any live stage | bead_closed | done | |
   | done | bead_reopened | queued | |
   | queued | jump (observed: the board's Jump to front) | stay | |
   | everything else: observed events ignored, claimed events invalid | | | |

   Live stages: queued, dispatched, building, reported, in_review, committed, pr_open, merged. Every transition also broadcasts. Tickets seen for the first time are backfilled (closed to done, open to queued) as recorded backfill events.
8. **Epic machine** (user: epics get their own tracked state, with the coordinator's recommendation): epics have a stage of their own for the stretch before tickets exist; after that their state is derived from their children (progress closed/total plus a stage histogram), not tracked twice.

   | From | Event | To | Effects |
   |---|---|---|---|
   | (new draft) | create (claimed) | idea | record draft title, spec link |
   | idea | start_spec | speccing | |
   | speccing | approve_spec | spec_approved | record spec link |
   | spec_approved | ticket [beads epic id given] | ticketed | link the beads epic |
   | idea, speccing, spec_approved | abandon | abandoned | |
   | abandoned | revive | idea | |
   | any | bead_epic_closed (observed) | done | |
   | done | bead_epic_reopened (observed) | ticketed | |
   | everything else: observed ignored, claimed invalid | | | |

   Draft epics live only in the overlay until `ticket` links them to a beads epic. A draft is keyed by a slug (`draft:<slug>`); its project is the configured repo containing the caller's working directory, or `--project`; its spec link is the spec file `/tight-spec` writes. Only project-size specs create a draft. `/to-tickets` finds the draft by slug and sends `ticket` with the new beads epic id (agent call). Beads epics the board first sees are backfilled to `ticketed` (or `done` when closed). From `ticketed` on, the epic's displayed stage is derived from its children: building once any child is past queued, shipping once all open children are committed or later, shipped when all are closed. Beads epics never get a ticket stage.

   **What sits under an epic** (user: work derives from epics): its planned tickets (parent-child, any depth) and its fallout (tickets linked `discovered-from` to anything under the epic), shown apart. A ticket that is both a child and `discovered-from` counts as fallout (user, mockup review). Tickets in another repo join an epic through a board-side link (`foreman attach <ticket> --epic <epic>`, stored in Postgres; beads untouched, descriptions never parsed) (user). Sub-epics are expandable rows under their parent; the parent's counts roll up the whole tree (user). Tickets with no epic above them, no `discovered-from` link and no board-side link are orphans.
9. **Forge boundary** (user): a forge behaviour with change requests (number, title, source and target branch, head sha, draft, checks, mergeable), list, merge-with-expected-head and retarget, and declared capabilities (head guard, retarget). The merge machine's guards read capabilities: without a head guard the board re-reads the head immediately before merging and says the guard is weaker; without retarget it stops after the merge and shows the manual step. The MVP ships the GitHub adapter (token from the logged-in `gh` at boot, HTTP through Req) and an in-memory fake forge for tests. Config names the forge per repo.
10. **Merge safety** (agent call): bottom of a stack only; not draft; checks passing or absent; mergeable; merge commits only; expected head sha; confirmation dialog names the CR, target, head sha, linked beads and the follow-up retarget; then the child is retargeted onto the default branch; no branch deletion. All rules enforced in the job, not only the UI; every merge recorded in an audit table. Merge action machine (UI): idle, confirming, merging, retargeting, merged, failed.
11. **Agent tools** (agent call): an HTTP API on localhost with a bearer token kept under `~/.ssh`, plus a `foreman` CLI that resolves the repo from the bead id prefix, never blocks or fails an agent (when the app is down it writes the event to the spooled-events table and exits 0; if Postgres is down too it prints a warning and exits 0; the app replays the table on boot), exits 3 with the allowed events on an out-of-order claim, and has `--json`. Observed events cannot be posted through the API.
12. **Skills integration** (user): in the MVP, as its last slices once the CLI is proven: `/tight-spec` and `/to-tickets` drive the epic machine; `dispatch` records sessions; the brief template has build sessions send `progress` and `report`; the coordinator's close-out sends `review`, `request_changes`, `commit`; a new `foreman` skill teaches the verbs. These are tickets in the skills repo, linked to this epic.
13. **Views** (user: epic-first; layout an agent call): the home view is **initiatives**: every epic across projects as a row with its stage (draft stages for ideas and specs, derived stages once ticketed), progress bar, ticket-stage histogram, fallout count and open change requests; draft epics sit at the top; sub-epics nest as expandable rows; one **Unplanned** lane at the bottom holds orphan tickets, collapsed by default and grouped by project with counts, opened per project (user). Opening an epic shows its tickets on stage columns (columns from config: groups of ticket stages), planned and fallout shown apart, plus the blocking graph. Filters: project, type, label, beads status, stale badge. Ticket detail sheet (beads fields, stage, stage history, sessions, agent notes, linked CRs, allowed next events). CR panel per project (stack order, checks, links, merge action). Settings (config source, validation result, reload, repos found on disk but not configured, with a block to paste). Config columns validate against the ticket machine's states; epic stages are not configurable. **The mockup is revised to this layout and approved by the user before any view is built** (approved 2026-10-17: canvas version 9, source in `docs/mockup/`).
14. **Bootstrap** (user): foreman tracks its own build in beads during bootstrap, in its own repo initialised the house way (embedded store plus `issues.jsonl` export on every commit; bd 1.1 has no working store-less mode). The skills-repo tickets for Decision 12 name their foreman parent in their description; cross-repo dependency edges are out of scope. Once the board runs, foreman is an ordinary configured repo on it.

15. **Ticket priority** (user, fm-c2w.23; the path is an agent call): P0..P4 from the ticket file (or beads export) shows on every ticket row, card and detail, P0 and P1 coloured; each ticket and epic shows and sorts by its own priority (no inheritance). The app never writes ticket files, and no board-to-CLI write path exists, so a change made on the board is a Postgres override that wins over the file and shows as "changed on board" until a file sync carries the same value, which deletes it (setting the file's value deletes it too). `foreman update <id> --priority N` stays the file write. Ordering: `foreman ready` by priority, then oldest created, then id (dispatch's ready-repos reads it); Initiatives epics by priority, then derived stage, then id; epic tickets by priority, then id; Standalone work and Unplanned by priority, then newest; Needs you by the request's ticket priority, then oldest; a missing priority sorts after P4. **Jump to front** on a queued ticket sets the P0 override and records the observed `jump` stage event; a jump is pending while the ticket stays queued, and `foreman ls --overlay --json` returns pending jumps (`jumps`, newest first) and the overrides the files do not carry yet (`priority_overrides`) for the coordinator to read first and carry into the files with `foreman update`.

## Acceptance checks

1. Every configured beads repo appears (today's six plus foreman); we_go_next_dev shows unreachable and the rest sync; ticket counts per repo equal `bd list --all` length at the same moment.
2. A `bd note` or `bd create` in form-engine shows on the board within 5 s without a reload (30 s if the probe forced the slower rule); an untouched repo costs no database writes on a sweep (hash skip, visible in logs).
2a. The probe's loop of agent-style `bd` writes (create, update, note, close) running against the live board on a scratch repo for 10 minutes has zero failed writes; the board's failed or skipped reads, if any, show only in its own logs.
2b. The initiatives view shows form-engine's fe-813 and fe-lwp as epic rows with derived stages and progress matching `bd`; a ticket with `discovered-from` under fe-813 shows as fallout under it; a ticket with no epic shows in Unplanned.
3. Running a real dispatch through the `dispatch` skill (fe-813.4 or the next ticket) moves its card to dispatched with window, branch and brief, then to building and reported as the pi session sends `progress` and `report`, then to in_review and committed as the coordinator closes out, with no manual `foreman` call by the user.
4. A claim out of order (`foreman review` on a queued ticket) exits 3 and prints the current stage and allowed events; the refused claim appears in the ticket's history as invalid.
5. With the app stopped, `foreman progress` exits 0 with a warning and its event sits in the spooled-events table; after start it applies and shows in history. With Postgres stopped too, it still exits 0 with a warning.
6. `/tight-spec` on a new idea shows a draft epic moving idea, speccing, spec_approved; `/to-tickets` turns it ticketed and the board shows its children.
7. Each DSL compile check has a fixture that fails to compile with the documented message; the committed stage, epic and merge-action diagrams match a fresh render.
8. In the scratch forge repo, through the UI: merging the top of a two-CR stack is refused; merging the bottom produces a merge commit at the confirmed sha; the child is retargeted to the default branch; a moved head between confirm and merge is refused; the linked ticket goes to merged and the UI suggests the `bd close` command.
9. form-engine's real open PRs show in stack order with links to their beads, read-only, and no merge is possible on a CR whose base is not the default branch.
10. Editing `foreman.toml` to add a column updates the board live; a column naming an unknown stage shows an error in settings and the old config stays in force.
11. The repo tree contains no license material and no local operator path (`mix precommit` guard plus the global commit hook); the running board adds or changes no tracked file in any beads repo (`git status` in every configured repo before and after a day's use; planned skills-repo edits excluded). The app keeps no data outside Postgres apart from the config file and the token.
12. Screenshots of the initiatives view, epic view, ticket sheet, CR panel and settings, light and dark, match the approved revised mockup's layout and Fluxon styling.

## Verification plan

- `mix precommit` (format, zero warnings, credo if adopted, tests) is the gate for every slice.
- Seams: the pure machines (`step/3`, compile-fail fixtures, generated-doc goldens, property tests over random event sequences); the beads reader (against scratch copies of real repos and a fixture export); the forge contract suite (fake forge in `mix test`; the GitHub adapter against recorded responses in `mix test` and live against the scratch repo when the adapter changes); LiveView tests for each view; the `foreman` CLI end to end against a running app.
- Outside the code: the real-dispatch walk-through (check 3), `git status` across all six repos (check 11), and screenshot review against the mockup (check 12).
- Concurrency probe (`bd export` loop against a loop of agent-style writes on a scratch copy of a repo) before the reader; its result and the chosen read rule are recorded in the repo's docs.

## Ask-first boundaries

- Creating the scratch forge repo on GitHub, or any other outward action (PRs, merges) outside it.
- Any write to a beads store or a beads repo, including hooks.
- Installing system software, systemd units, or touching dotfiles (the config file and env exports go in through the user or a dotfiles ticket).
- Adding a forge adapter beyond GitHub, or a feature outside Decisions 7–13.
- Changing the stage or epic machine's states or events beyond the tables above.
- Building any view before the revised mockup is approved.
- Any storage outside Postgres beyond the config file and the token.

## Left to the builder

- Schema details, module layout, Oban queue names and cron times within the stated bounds.
- Exact poll intervals and sweep timing, within "visible within 5 s" and "no writes when unchanged".
- CLI flag spelling and output format, keeping the verbs in Decision 7, 8 and 11.
- Fluxon component choice per view, staying within the mockup.
- Whether the `foreman` skill is one skill or folded into `dispatch`/`flow`, as long as each workflow step calls the verb.
