---
id: fm-zgd.9
title: "Needs you session cards: an Open session button and inline answers, never a bare attach command"
type: feature
status: closed
priority: 2
parent: fm-zgd
blocked_by: ["fm-zgd.8"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: 2026-10-19
close_reason: "Merged into main 3f522f0 (49be583); CLI escript rebuilt."
---

User request 2026-10-19: 'I never want to see an alert like that' (a Session waiting card showing only 'Input needed' and 'tmux -L default attach -t coordinator:@38'). Every session_waiting card in Needs you (page and drawer) must give the user a way to act in one click.

## Behaviour
- Title names the session in words (coordinator, planning session title, or build name / ticket), not a tmux target.
- **Open session** button on every session_waiting card: selects the window and pane (SessionTmux.focus/2 already does select-window and switches the latest client), then brings the terminal app to the front on macOS (osascript activate of a configured app; the user runs Ghostty, WezTerm is also installed; config key in foreman.toml with a sensible default, no-op on Linux). If no tmux client is attached, say so on the card and show the attach command as small copyable text below the button, never as the main content.
- **Answer inline** where the hook gives enough data:
  - AskUserQuestion: store the question text and option labels in the request facts (not secret; answers stay out). Render the options as buttons plus an 'Other' text field. Choosing one sends the keystrokes to the session's pane (tmux send-keys, text and Enter as two calls) and resolves the request. If the pane no longer shows that prompt (snapshot/digest changed), refuse and fall back to Open session.
  - Permission requests: show the tool name only (no command text in the DB, as today). Offer Open session; inline Allow/Deny only if the pane's permission prompt can be matched reliably, otherwise Open session only.
  - Usage limit: keep Continue, add Open session.
- Declare any new request/answer states on the existing Foreman.Fsm machines (house rule).

## Acceptance
- No session_waiting card renders without an Open session button (LiveView test over all three reasons).
- Open session calls focus and the terminal-activate step (stubbed command runner), and shows a clear message when nothing is attached.
- AskUserQuestion card shows question + options; choosing an option sends the expected keys to a scratch tmux pane and resolves the request; a changed pane refuses.
- Screenshots of the card (light/dark, desktop and 390px).
- mix precommit: same environment failures as base only (see drafts/sessions/coord-idle.md for the known macOS/worktree list).
