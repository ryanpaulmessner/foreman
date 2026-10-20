---
id: fm-0j9
title: "Environment variables and secrets: tracked per project and environment, values in a real secret store"
type: epic
status: in_progress
priority: 1
parent: null
blocked_by: []
related: []
supersedes: []
discovered_from: null
labels: []
created: 2026-10-19
closed: null
close_reason: null
---

User request 2026-10-19: stop remembering which env vars a push needs and who to tell. Track names and status, never plaintext values. Related: work-4cs (release planning, ~/dev/work) — release notes and the dev-team message should list env changes.

Sketch (to be specced with /tight-spec):
- Registry per project: name, which process reads it (web/worker), environments that need it (local, preview, staging, prod), secret or not, purpose, the PR/ticket that introduced it.
- Status per environment: set/missing on staging and prod, team informed.
- Auto-capture: scan PR diffs for new System.get_env / System.fetch_env! reads (config/runtime.exs etc.) and add them as 'new, needs a value'.
- Board: an Environment page per project, a badge on PRs/releases that add variables, a Needs you card when an environment is missing one.
- Secret values: macOS Keychain (security CLI) for the local machine, replacing ~/.ssh files (Asana PAT, staging/prod DB credentials, foreman CLI token); the DB stores only references like keychain:<service>/<name>. Team/staging/prod: Azure Key Vault (needs Arnoldo/IT). Open question: does IHS already use Key Vault or a password manager?
