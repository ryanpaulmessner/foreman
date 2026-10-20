---
id: fm-zgd
title: "Approvals inbox: push, PR, merge and build questions on the board"
type: epic
status: open
priority: 1
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-18
closed: null
close_reason: null
---

# Approvals inbox

Status: approved 2026-10-18. Board draft epic `draft:approvals-inbox`.

## Goal

After `/to-tickets`, every input the workflow needs from the user (push a branch, open a PR, merge a PR, answer a build-time question) waits as a request on the board, and the board's worker carries out approved actions on the repo's forge.

## Why

The user wants the board to own the ticket lifecycle from `/to-tickets` on, and to stop being interrupted in the terminal for routine assents. Requests sitting in tmux windows go unseen (bb-flaky waited at a decision; sk-board waited four hours at a prompt). Success: the user approves pushes, PRs, merges and build questions from one page, gets an OS notification when something arrives, and the waiting session or coordinator continues on its own.

## Non-goals

- Standing or automatic approvals. Every action is an explicit click for now (user); the request shape leaves room to add them later.
- `/tight-spec` interviews, `/grilling` and other live conversations: they stay in the terminal (user). Only questions raised by build sessions and coordinator close-out go to the board.
- Force pushes, branch deletion, rebases, squash merges, editing PRs after creation, reviewing diffs in the board.
- Agents pushing. The agent push hook stays exactly as it is; the board's worker is the only pusher.
- Deployment, remote hosting, multiple users. The board is a local, single-user tool for good (user); each app handles its own deployment.
- Forges other than GitHub; Windows-native or push-service notifications.
- Writing to beads (unchanged: read-only).

## Decisions

1. **Requests are the unit** (user). A request is a typed ask from a known asker (actor and session, as the CLI already records) about one ticket or epic: `push`, `open_pr`, `merge` or `decision`. Each names exactly what will happen; nothing outside the named facts is executed.
2. **The board's worker executes approved actions** (user). Approval in the UI enqueues one job; the job re-checks every guard against live facts, acts once, and records the attempt. A rescued or retried job never repeats an external write (same one-shot claim and audit pattern as the merge action).
3. **Everything happens on the repo's forge** (user). Pushes, PRs and merges go to the repo's configured GitHub remote through the user's `gh` login. A repo with `forge = "none"` gets no push or PR requests; its slices end at commit.
4. **Credentials** (user, agent call on mechanics). Pushes run over HTTPS with `gh` as git's credential helper for that one command, so one credential (the `gh` login, read at worker boot as today) covers push, PR and merge; the service never uses the user's SSH keys and never writes credentials to disk or argv. The user's own terminal pushes keep using SSH.
5. **Supersedes two MVP non-goals** (user): the board now creates PRs and runs one local git command (`push`), and nothing else locally: no fetch into worktrees, no checkout, no commit.
6. **Request kinds and their guards** (agent call). Guards are checked when the request is created (refuse a bad ask early) and again in the job.

   | Kind | Facts named | Guards at execution |
   |---|---|---|
   | push | repo, worktree, local branch, expected local sha, remote branch | worktree belongs to the configured repo (same git common dir); local branch still at the expected sha; remote branch absent or an ancestor of the sha (fast-forward only); never `--force` |
   | open_pr | repo, head branch, expected head sha, base branch, title, body | head branch on the remote at the expected sha; base exists; no open PR for that head |
   | merge | an existing PR at an expected head | the existing merge rules (spec Decision 10), unchanged; approving opens the existing confirm flow |
   | decision | question, options, recommendation, optional free text | none; answered, not executed |

   A push or PR asked while the ticket is not yet `committed` is refused at creation.

   **Default branch** (user): a push to the repo's default branch is allowed only for a one-off ticket (no parent epic: the Unplanned group), fast-forward only. Work inside an epic reaches the default branch only through a PR; a default-branch push for it is refused at creation and again in the job.
7. **Request machine** (agent call), on `Board.Fsm`:

   | From | Event | To | Effects |
   |---|---|---|---|
   | — | ask | pending | record, notify |
   | pending | approve (action kinds) | approved | enqueue job |
   | pending | answer (decision) | answered | record answer, tell asker |
   | pending | decline | declined | record note, tell asker |
   | pending | withdraw (asker) | withdrawn | |
   | pending | facts_changed (observed: sha moved, ticket abandoned or done, PR closed) | superseded | tell asker |
   | approved | start | executing | audit intent |
   | executing | succeeded | done | audit, tell asker |
   | executing | failed | failed | audit with reason, tell asker |
   | executing | orphaned (job rescued) | failed | audit "outcome unknown", tell asker; never re-run |
   | everything else: claimed events invalid, observed events ignored | | | |

   A failed or superseded request is never retried in place; the asker posts a new one.
8. **Asking and waiting** (agent call). The CLI gains `board ask <kind> <ticket> …` (returns the request id at once) and `board wait <request> [--timeout]` (prints the outcome as JSON when it resolves). Both keep the CLI rule: never fail an agent; a timeout prints the current state and exits 0. Build sessions ask a decision and wait in their own shell; the coordinator asks for push and PR at close-out and waits in the background.
9. **The page** (agent call; Fluxon, house copy rules). A "Needs you" page, linked first in the sidebar with a count badge, lists pending requests oldest first. Each card shows the facts from Decision 6 and the ticket, then Approve and Decline (with an optional note); a decision shows its options with the recommendation marked, plus free text. Recent outcomes (done, failed, declined, superseded) below, collapsed. The ticket sheet shows that ticket's requests in a Requests tab.
10. **Notifications** (user). An in-app count in the sidebar and the tab title (`(2) beads-board`), plus one browser notification per new pending request through the Notification API, which shows as a native toast on Windows and in Notification Center on macOS. Permission is asked only from an explicit "Turn on notifications" control, never on load. Needs a board tab open (any, background is fine); no push service.
11. **Skills integration** (user: board owns the lifecycle after `/to-tickets`). `dispatch`: build briefs say to ask build-time questions through `board ask decision` and wait; close-out posts push and open_pr requests after the commit instead of asking in the terminal, and waits for them before the next step. `board` skill documents the new verbs. The "agents never push" rule stays and gains a line: pushes go through board requests.

## Acceptance checks

1. Push, against `rpmessner/beads-board-scratch`: a request created by the CLI for a committed ticket appears on the page and fires one browser notification; approving it puts the branch on GitHub at exactly the named sha; the audit shows one attempt.
2. Moving the local branch after asking marks the request superseded before approval; approving a request whose remote branch diverged fails with "not a fast-forward" and pushes nothing.
3. Open PR, scratch repo: approval creates the PR with the named base, title and body; the ticket moves to `pr_open` through the observed read, not through the request.
4. Merge: approving a merge request runs the existing confirm flow; acceptance check 8 of the MVP spec still passes.
5. Decision: a real pi build session posts a question, the user answers on the board, and the session's pane shows it continuing with that answer, with no terminal input.
6. Decline with a note: the asker's `board wait` prints declined and the note; nothing executes.
7. Killing the worker while a push job runs leaves the request `failed` with "outcome unknown" after rescue, and no second push happens.
8. Notifications: the badge and tab title track the pending count across two open tabs; no permission prompt appears without the control being clicked; with permission, exactly one notification per new request.
9. A real dispatch close-out (next ticket after this lands) pushes and opens its PR through board requests, with no push or PR question in the terminal, and the agent push hook still blocks a direct `git push` by an agent.
10. A `forge = "none"` repo refuses push and open_pr requests at creation.
11. Scratch repo: a default-branch push for a one-off ticket succeeds as a fast-forward; the same push for a ticket inside an epic is refused at creation, and a job forced past creation (test seam) refuses it too.

## Verification plan

- Machine tests for the request machine (every row, invalid and ignored events); guard tests per kind against the fake forge and a temporary git repo with a bare remote (fast-forward, diverged, moved local sha, foreign worktree).
- Job tests with the one-shot claim: retry and rescue never repeat a write.
- Live scratch-repo run for checks 1–3 and 7, recorded as fixtures with tokens scrubbed (same approach as bb-merge).
- Browser runs (Playwright) for the page, the Requests tab and notification behaviour with permission granted and denied; light and dark, 390 and 1440 px; screenshots looked at.
- Check 5 and 9 with real pi sessions dispatched through the updated `dispatch` skill.

## Ask-first boundaries

- Any push, PR or merge outside `rpmessner/beads-board-scratch` during the build.
- Changing the agent push hook or any harness file.
- Adding a push service, a native notifier, or new credentials.
- Any local git command other than `push`.

## Left to the builder

- CLI flag names and JSON shapes beyond the facts in Decision 6.
- Page layout within the house design language and copy rules.
- How the worker locates the worktree (from the session record or the request's facts), provided Decision 6's guard holds.
- Slicing into tickets.
