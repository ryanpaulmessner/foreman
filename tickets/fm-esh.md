---
id: fm-esh
title: "Ask the agent about a card: question and answer thread inside the card"
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

Ryan, 2026-10-21: 'I'd like for foreman to be able to ask agents questions from a question block and have it answer in that question block in addition to the link to the chat window.'

Today a card can only be answered (the reply event sends the answer into the asking session and closes the card). Ryan often needs to ask 'what does this mean?' first. Related: fm-9xi (card header), fm-knr (source session + Go to session), fm-5fq (answers page).

## What to build
- An 'Ask about this' box on every pending card. Sending it records a card message (author Ryan) and delivers it to the session that asked, using the same delivery as reply (prompt into a Claude coordinator's tmux pane; relay inbox / pane input for a Pi build), prefixed so the agent knows it is a card question: '[card question <request-id>] <text>'. The card stays pending.
- CLI for the agent: 'foreman card-reply <request-id> --body-file <md>' (or --text) records a card message (author = FOREMAN_ACTOR/session). The card shows the thread (Markdown, document links like other cards), newest last, live via PubSub.
- If the asking session is unknown or gone, the box says so and offers Go to session / the copy command instead of pretending to send.
- Answering, declining or withdrawing the card keeps the thread visible in Recent outcomes.
- New table for card messages (request_id, author, body, inserted_at); no change to the request FSM states.

## Acceptance
- [ ] Ask → message stored, delivered to the asking session (test with a fake delivery adapter for both Claude and Pi paths), card still pending.
- [ ] card-reply → message appears in the card without reload; refused for an unknown or finished request.
- [ ] Unknown/gone session → no send, clear message, fallback shown.
- [ ] LiveView tests for the box, the thread and the fallback; CLI tests.
- [ ] The foreman skill tells agents how to answer card questions (separate small change in the skills repo, coordinator does it).
