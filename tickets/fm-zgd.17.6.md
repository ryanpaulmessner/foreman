---
id: fm-zgd.17.6
title: "Ask holds the question and sends it when the session reaches an empty prompt"
type: task
status: open
priority: 2
parent: fm-zgd.17
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-04
closed: null
close_reason: null
---

Ryan, 2026-11-04 (card e144ba3b, "Hold and send"; from his live check on chore f80b06e6): pressing Ask on a card from a working session showed a red "The question was not sent. The session is not at an empty prompt." and the question was lost.

## What to build
- When Ask cannot type into the session because it is not at an empty prompt, the board keeps the question and sends it the next time the session's lifecycle state reaches idle or waiting (fm-9mm.10 machine) and the prompt is empty.
- The card shows an info line, not red: "Waiting to send: <session> is working." with Cancel. Cancel puts the text back in the box.
- When it is sent, the question shows in the card thread as today. If the session ends before it can be sent, the info line changes to the Decision 18 ended-source copy with the text in the copy field.
- The held question is stored on the board (Postgres), so a reload or a board restart does not lose it; at most one held question per card.
- Extend `Foreman.CardAsk` with the held state (declared machine, generated docs page).

## Acceptance
- [ ] Ask on a working session holds the question; the card shows the info line and Cancel (LiveView test).
- [ ] The held question is typed in when the session goes idle, once, and shows in the thread (test with the lifecycle event).
- [ ] Cancel returns the text to the box; a reload keeps the held question (test).
- [ ] Session ends while held: ended copy with the text in the copy field (test).
- [ ] verify ui of the held line at 1440 and 820, light and dark.
