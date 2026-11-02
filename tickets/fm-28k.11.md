---
id: fm-28k.11
title: "Formal check: request lifecycle cannot stick in approved"
type: feature
status: open
priority: 2
parent: fm-28k
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-30
closed: null
close_reason: null
---

Retro F2 (create-formal-verification-skill): the reconciler's 90 s orphan rule races the 60 s job timeout, so a request can stay approved; SessionWaiting.ask does not check for a Done ticket. Model request states, worker job, reconciler and ticket close in TLA+; property: every approved request reaches done, failed or superseded.
