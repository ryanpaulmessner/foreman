---
id: fm-9mm.13
title: "Session page: recent output and saved output"
type: task
status: closed
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.12"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: 2026-11-05
close_reason: "PR #17 merged (72a31dd); deployed 2026-11-05 with session_captures migration; live session page 200"
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decisions 14-15.
- A declared pane reader machine (off, polling, paused, tmux error) that runs `tmux capture-pane -p -e -J -S -200 -t <pane>` once a second only while a page shows that pane's output tab and the tab is visible; pushes only when the hash changes.
- Board-owned ANSI-to-HTML converter: SGR 16/256/truecolor mapped to theme tokens, OSC 8 links; no new dependency. Output panel dark in both themes.
- `session_captures`: the last output per session, saved at agent exit (launch command), before Stop and Park, and the latest poll as fallback. Dead view shows it with its "Saved <time> ..." head line (copy table).
- Output states: loading skeleton "Reading the terminal…", "No output yet.", "No output was saved for this session.", tmux error head line.

## Interfaces
- Produces the capture save call used by the live controls ticket (Stop, Park) and the reader machine reused by the Grid ticket.

## Design pack
State "Proposed: pane reader"; Flows "how the tree and grid stay current".

## Acceptance
- [ ] On a scratch tmux server a live detail page shows output within 2 s of the agent printing it; no `capture-pane` runs for a pane no page shows (tmux command log; spec acceptance 5).
- [ ] Converter table tests for SGR and OSC 8.
- [ ] Machine tests for the reader states; hidden tab stops polling.
- [ ] Dead view shows the saved output with the right head line for exit, last check, Stop and Park.
- [ ] verify ui screenshots of live, empty and dead output at 1440 and 820, light and dark.
