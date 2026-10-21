---
id: fm-5fq
title: "Answers: a board page that keeps coordinator answers to Ryan's questions"
type: feature
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

Ryan, 2026-10-21: when he asks the coordinator a question, the answer lives only in a long agent session. It scrolls away, or a context summary drops it, and he has to scroll back to find it. He wants each answer kept on the board where he can see it well and come back to it.

Seen today: the meaning of a stale card was explained three times; staging verification results were lost in the scroll (now notes/staging-verify-2026-10-21/README.md, ticket work-4cs.2).

## Sketch (capture; needs a spec)
- `foreman answer --question "..." --body-file <md> [--ticket <id>] [--repo <key>]` stores a question, the answer (Markdown) and links (ticket, files) with time and session.
- An Answers page: newest first, search, filter by repo/ticket; each answer expands; links to documents like Needs you cards; pin and archive.
- Coordinator skills (dispatch, slice-loop, foreman, orient) post an answer whenever Ryan asks a question that needs more than a two-line reply, and say the link in chat.
- Relation to fm-49x (This week) and Needs you: answers are reference, not asks; This week can link the week's answers.

## Open questions
- Free text or tied to tickets only? Edit or append after posting? Keep forever or expire?
