---
id: fm-zgd.14
title: "Needs you cards link to documents and open them in the board's document viewer"
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
close_reason: "Merged into main 6ea084d; CLI rebuilt (ask decision --doc)."
---

User request 2026-10-19: when a card (decision, question, push/PR) references a planning document, spec, report or review, show it as a link that opens in the board's document viewer (/documents/:repo, Foreman.Documents / Documents.Viewer), not as a bare path to copy.

Behaviour:
- foreman ask decision gains a repeatable --doc <path> (repo-relative or absolute under a configured repo); stored in request facts as {repo, path}. Paths outside configured repos are refused at ask time.
- Also auto-detect paths in the question/--text (and in fm-zgd.11 chat-question text) that resolve to files in a configured repo, e.g. slices/…/reviews/27-r1.md, epics/…/spec-2b-openness.md, docs/specs/env-and-secrets.md; render them as links. No link for paths that don't exist.
- Links open the viewer on that document (deep link with the path; Markdown rendered, file:line anchors scroll to the line when the viewer supports it). Opening in a side panel/drawer from the card is preferred so the card stays in view.
- Works on the Needs you page, the drawer and Recent outcomes. Same links in fm-zgd.13 native notifications are out of scope (a click there opens Needs you).
- Update the foreman skill and slice-loop/AGENTS.md guidance: pass --doc for the report/review/spec a question is about.
Acceptance: LiveView tests for explicit --doc and detected paths (existing vs missing file, path outside repos refused), viewer opens at the path; screenshots light/dark desktop/390px; mix precommit only base env failures.

## Notes
- 2026-10-19 user: 2026-10-19 user: question cards lose formatting — 'it's all just one big run-on paragraph'. Render card text as Markdown with the board's safe renderer (paragraphs, lists, bold, code, tables, links) everywhere a card shows agent text: decision question (needs_you_live.ex:514 renders it in an <h2> with no line breaks) and --text (:516), chat-question text (:300, fm-zgd.11; also check ChatQuestion keeps newlines and does not flatten the closing paragraph plus its option list), push/PR facts, Recent outcomes. Long text: first lines + 'Show more'. Detected file paths (this ticket) become links inside the rendered Markdown.
- 2026-10-19 user: 2026-10-19 user: next to document links, every card also shows a link to its ticket (the card's bead_id, e.g. work-8ec.7) that opens the ticket detail in the same side panel/drawer, so the user can read the ticket body, history, reports and session for context without leaving the card. Use the existing TicketDetail component (/needs-you?ticket=<repo:id> already opens a ticket); make it a side panel next to the card on desktop, a sheet on mobile.
