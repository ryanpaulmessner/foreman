---
id: fm-zgd.11
title: "Needs you: a session that stops on a question gets a card with the question and a Reply box"
type: feature
status: closed
priority: 2
parent: fm-zgd
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: 2026-10-19
close_reason: "Merged into main e4af046; CLI escript rebuilt from the worktree and installed."
---

User request 2026-10-19: 'when you need me I need to see notifications in my inbox and a way to answer them that isn't just a command for tmux'. Rule now: agents post gates as foreman ask decision (workspace AGENTS.md, slice-loop). This ticket is the safety net for when a Claude session forgets and asks in plain chat.

Since fm-zgd.8 an idle Stop makes no request, so a session that ends its turn with 'Shall I commit?' is invisible. Behaviour:
- On Stop from a coordinator/planning/external Claude session, read the turn's last assistant message (Stop hook input: last_assistant_message if present, else the tail of transcript_path). If it ends by asking the user something (a question to the user in the last paragraph; keep the classifier simple and tested: trailing '?' in the last paragraph, or 'Say "..."' / 'Shall I' / 'Should I' / 'Do you want' patterns), raise a session_waiting request with reason 'question' and the last paragraph as the question text (cap length; it is the agent's own words, not secrets).
- Otherwise behave as fm-zgd.8 (no request).
- The card (fm-zgd.9 layout) shows the question text, Open session, and a **Reply** text box. Reply types the text into the session's prompt (text, then Enter, as two send-keys calls) only when the pane shows the idle Claude input prompt (match the prompt line; refuse otherwise and keep Open session). The request resolves on the next UserPromptSubmit/resume, as today.
- Browser notification for new requests already exists behind 'Turn on notifications'; make sure question requests trigger it.

Acceptance: Stop with a trailing question → one request with the text; Stop without → none; Reply sends keys to a scratch pane showing an idle prompt and refuses on a busy pane; card screenshots light/dark desktop/390px; mix precommit only the base's known environment failures.
