---
id: fm-9mm.16
title: "Continue on another model: checks, then Resume on <model> for Pi builds"
type: task
status: open
priority: 2
parent: fm-9mm
blocked_by: ["fm-9mm.15"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-11-03
closed: null
close_reason: null
---

Spec: `docs/specs/sessions-view.md` (approved 2026-11-03, card cfb2bce5). Design pack: `docs/specs/sessions-view.design.md`. The spec's Non-goals, Ask-first boundaries and copy tables apply to every ticket.

## What to build
Spec Decision 19 (Ryan: "have a way to fallback to other models").
- Check first, in a scratch worktree: does `pi --session-id <id> --model <other>` keep the conversation and use the new model across providers? Record the result on this ticket.
- Check first: does `claude --resume <id> --model <other>` keep the conversation and switch model, and does an Anthropic usage limit block every model or one? Post the result to Ryan as one decision card; build no Claude control before he answers.
- Then: fallback pairs in board config (start: `openai-codex/gpt-6-astra` <-> `anthropic/claude-opus-5-5`). At a Pi usage limit with a pair, "Resume on <model>" saves the capture, stops Pi, resumes the same session with `--model`, and updates the row's `model`. If the Pi check fails, the button is "Relaunch on <model>" through the coordinator note.
- Continue stays on and the page shows the reset time.

## Acceptance
- [ ] Both check results on the ticket, with the commands run.
- [ ] Claude decision card posted and answered before any Claude control.
- [ ] Context test: Resume on model changes `model` and keeps the row id; no pair -> no button.
- [ ] verify ui of the usage-limit panel with and without a fallback.
