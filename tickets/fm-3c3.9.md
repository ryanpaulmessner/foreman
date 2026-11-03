---
id: fm-3c3.9
title: "Session waiting and Continue for pane-mode pi builds"
type: feature
status: closed
priority: 2
parent: fm-3c3
blocked_by: ["fm-3c3.8"]
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: 2026-11-03
close_reason: "Superseded by fm-9mm.14 (Continue to pane-mode builds, Sessions spec Decision 17, acceptance 8)."
---

Pane-mode builds (dispatched by an epic coordinator with pi-window --pane) record a %pane-id in the dispatch window field, but SessionWaiting.target/4 resolves targets through SessionTmux.external_target/2, which only accepts window names/IDs. A pane build that hits a usage limit or waits on input therefore can't be targeted by Continue. Found in fm-3c3.8 review.

Acceptance: a pane build's session_waiting request resolves to its %pane on the right server; Continue sends exactly continue+Enter to that pane only, never the coordinator pane; window-mode builds unchanged; scratch tmux transcript; mix precommit green.
