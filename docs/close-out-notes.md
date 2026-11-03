# Merge list and close-out notes (fm-fdw)

Needs you shows only work a person does. Agent close-out work that is stuck goes to the
coordinator that owns it, as a note, not to Needs you.

## Pull requests for you to merge

`Foreman.WaitingWithoutCard.list/0`. One row per open PR in an enabled GitHub repo under
the human-merge policy, when the PR belongs to a ticket in that repo and no pending card
covers it. A PR belongs to a ticket when it links the ticket (title, branch or body) or its
head branch is a branch recorded for the ticket: the dispatch `--branch`, or the branch on
a push or open-PR card. PRs whose tickets are all parked (`parked` or `deferred`) are not
listed. Age is the PR's GitHub `createdAt` (older snapshots show "—" until the next sync).
The only control is **Open on GitHub** (new tab). The section is hidden when empty.

## Stuck agent work

`Foreman.WaitingWithoutCard.stuck/0`, for live tickets that are not parked and have no
pending card:

| Kind | When | Next command in the note |
| --- | --- | --- |
| report | stage `reported` | `foreman review <id>`, then close out |
| push | stage `committed` in a repo with a forge, no push card approved, running or done | `foreman ask push <id> ...` |
| decision | a decision ticket that blocks live work | `foreman ask decision <id> ...` |

A ticket is not stuck when a push for it is done or a PR for it (by link or branch) is open
or merged: open PRs are on the merge list; merged ones are shipped.

## Notes to the owner

`Foreman.CloseOutNags.run/1` runs once a minute on the worker (`Foreman.CloseOutNagMonitor`)
and follows the `Foreman.CloseOutNag` machine (`docs/machines/close_out_nag.md`):

- First note when the item has been stuck 30 min; then every 3 h while it stays stuck. A
  note that found the owner's pane busy is tried again after 10 min. An item with no owner
  is recorded once and waits for a change. The timings are module attributes in
  `Foreman.CloseOutNag`.
- "Stuck since" is the later of the ticket's last stage change and its last card change. A
  change of stage or cards starts a new schedule; an item that is no longer stuck stops.
- The owner is the coordinator recorded on the ticket's latest dispatch. `foreman dispatch`
  takes `--coordinator <name>`; without it the CLI sends `TMUX_PANE` and the board records
  the registered, running session in that pane (pi-window runs in the coordinator's pane).
  For work a coordinator built and committed itself (`commit` with source `coordinator`),
  the owner is that commit's session. Dispatches recorded before this change have no
  coordinator.
- One note per owner per pass, through `Foreman.CoordinatorNote.send_to/3`, naming each due
  ticket, what is missing and the next command (one line, at most 2000 bytes; tickets that
  do not fit wait for the next pass).
- Each attempt is a row in `close_out_nag_notes` and shows on the ticket's Stage history as
  `note_to_coordinator`: `delivered`, `skipped` with the pane reason (pane busy, pane gone,
  session ended, coordinator not registered) or `ownerless` with why (not dispatched, no
  coordinator recorded on dispatch, no session on the coordinator's commit). Nothing falls
  back to Needs you.
- The preview (`PREVIEW=1`) never sends notes.
