---
id: fm-9mm.1
title: "Session identity: how every ask, build and coordinator records its own name and parent"
type: decision
status: closed
priority: 2
parent: fm-9mm
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: ["wayfinder:prototype"]
created: 2026-11-01
closed: 2026-11-02
close_reason: "New agent_sessions table is the identity; parent, pane id and conversation id recorded at launch; asks resolved at accept time by name then pane; no backfill"
---

## Question

Today about 72% of question cards have a broken source when they are created (see the map Notes). Decide the identity model so that every request names the session that asked and every session knows its parent:
- What fields a session row has (own name, harness, model, project, ticket, tmux server, window and pane id, workdir, branch, parent session, conversation or Pi session id, started/ended).
- One sessions table, or the current split (planning_sessions + dispatch rows + external session registrations) with a join view.
- How a coordinator registers itself at start (coord function, `foreman coordinator`, relay, epic launch) with its real window and pane, and how a build gets its own name with the coordinator as parent (pi-window, pane builds).
- What `foreman ask` does when it has no session: refuse, warn, or infer from $TMUX_PANE.
- What happens to the existing rows with a wrong or missing session.
Prototype: a design-pack data diagram, Now from code (planning_session.ex, external_session.ex, sessions.ex, request_source.ex, dispatch storage) and Proposed with changes marked. Evidence: the 2026-11-01 diagnosis numbers on the map.

## Notes
- 2026-11-02 user: Resolved 2026-11-02 with Ryan (prototype: design-pack data view, docs/specs/sessions-view.design.md, Data part). D1: new table agent_sessions is the only session identity (uuid id = Claude conversation id where it applies; name unique among live sessions = tmux window name; kind main_coordinator|epic_coordinator|build; parent_id; harness; model; conversation_id (Claude uuid or Pi session id); tmux_server; pane_id always %N; project; ticket; workdir; branch; state; started/last_seen/ended). planning_sessions, dispatch sessions rows (+agent_session_id) and approval_requests (+agent_session_id, set when the ask is accepted, never at render) point at it; session_captures holds the last output for the dead view. Writers: board launch and coord/foreman coordinator register themselves with $TMUX_PANE; pi-window dispatches with the build's own --name and --pi-session <uuid>, parent = caller's FOREMAN_SESSION; relay open registers builds with --parent. D2: ask resolves by name then $TMUX_PANE; no match = accept, card says source unknown, agent gets a warning (no refusal). D3: no backfill of the 524 old requests. D4: name unique among live sessions only; reuse after end, old cards keep pointing at the old row by id.
