# bb-cli: bb-c2w.7

Implemented and verified. No commits, pushes, bd commands, subagents, or user-directory installs. The coordinator owns ticket closure.

## Changes

- `Board.Agent`, `AgentCommands`, and `AgentCatalog` provide the claimed-event API, stable identity resolution, attach/detach, and idempotent request receipts.
- `Board.CLI` is the escript entry point. It does not start the board application. `CLITransport` uses Req for HTTP and Postgrex for the offline insert.
- `DeliveryMachine` declares HTTP/fallback/exit behavior. `SpoolMachine` declares pending/applied/rejected delivery. Both have generated golden docs.
- The migration adds `spooled_events` and `agent_receipts`. `SpoolWorker` runs only with the worker role, at boot and every three seconds. The web role has the authenticated `/api` routes.
- Board-side links work across repos and survive draft ticketing. Approving without a new spec or design link preserves the existing link. `--design` is optional and records `design_link`; the draft epic page shows the design document inline, including Mermaid diagrams. Beads content remains untouched.

## API contract

All routes require `Authorization: Bearer <token>`, including reads. The endpoint remains bound to loopback. Missing, empty, too-short, or incorrect credentials return `401 {"error":"unauthorized"}`. The app reads the token file for each request and never creates it.

| Route | Contract |
| --- | --- |
| `POST /api/tickets/:repo/:id/events` | Body contains `event`, optional `payload`, `actor`, `session`, and optional UUID `request_id`. |
| `GET /api/tickets/:repo/:id` | Returns `repo`, `id`, `stage`, and `allowed`. One forced sync precedes a missing-entity 404. |
| `POST /api/commands` | CLI envelope described below. Also supports `show`, which includes history, and `ls`. |
| `GET /api/repos` | Enabled configured repos, paths, and observed prefixes for identity resolution. |
| `POST /api/repos/:repo/sync` | Sends the worker a sync request. Returns `200 {"sync":"requested"}`. |

An event response is `200 {"stage":"building","effects":[{"kind":"append","name":"progress"},{"kind":"emit","name":"stage"}]}`. An out-of-order claim returns `409 {"stage":"queued","allowed":["dispatch","abandon"]}` and records an invalid history row. Unknown entities return 404 after one forced read. Unknown or observed events return 422. Invalid payloads return 422, not an out-of-order exit.

Ticket event names are `dispatch`, `progress`, `report`, `review`, `request_changes`, `commit`, `abandon`, and `revive`. Epic names are `create`, `start_spec`, `approve_spec`, `ticket`, `abandon`, and `revive`. No `bead_*` or `cr_*` event is accepted, including during replay.

The command envelope uses string keys:

```json
{"request_id":"<UUID>","action":"event","kind":"ticket","id":"fe-813.4","event":"progress","payload":{"body":"working"},"actor":"pi","session":"fe-loop","cwd":"<caller directory>","project":null}
```

`action` is `event`, `attach`, `detach`, `show`, or `ls`. Link requests add `epic` and optional `epic_project`. List requests accept `stage` and `project`. The explicit HTTP ticket route supplies `repo`; ordinary CLI envelopes resolve it from the observed ID prefix. Drafts resolve by slug and the deepest configured directory containing `cwd`, or `--project`. Ambiguous prefixes are refused rather than guessed. Before a repo's first projection, use `--project`.

Every accepted write and invalid machine claim pings its repo. Attach/detach also ping the epic's repo. Request UUIDs make an uncertain HTTP response safe to spool: the first terminal result and effects commit together, and a repeat returns that result. Reusing a UUID with different content returns 422. Direct callers should supply UUIDs when they retry.

## CLI contract

The CLI returns 3 only for a 409 carrying a stage and allowed events. Every other handled failure returns 0 with a one-line warning. `--json` applies to successful results, refusals, usage errors, and offline warnings. Read commands are never spooled. Use one ticket ID per invocation.

| Verb | Example |
| --- | --- |
| dispatch | `board dispatch fe-813.4 --window fe-loop --harness pi --model example --workdir "$PWD" --branch pr/looper --base abc123 --brief docs/briefs/fe-loop.md --report docs/sessions/fe-loop.md` |
| progress | `board progress fe-813.4 "recording works; wrap next"` |
| report | `board report fe-813.4 --path docs/sessions/fe-loop.md` |
| review | `board review fe-813.4` |
| changes | `board changes fe-813.4 "round the loop length to bars"` |
| commit | `board commit fe-813.4 --sha abc123` |
| abandon | `board abandon fe-813.4` |
| revive | `board revive fe-813.4` |
| epic create | `board epic create looper --project form-engine --title "Looper" --spec docs/looper.md` |
| epic spec | `board epic spec looper --project form-engine` |
| epic approve | `board epic approve looper --project form-engine --spec docs/looper.md --design docs/looper-design.md` |
| epic ticket | `board epic ticket looper --project form-engine --beads-epic-id fe-813` |
| epic abandon | `board epic abandon looper --project form-engine` |
| epic revive | `board epic revive looper --project form-engine` |
| attach | `board attach sk-5o2 --epic bb-c2w` |
| detach | `board detach sk-5o2 --epic bb-c2w` |
| show | `board show fe-813.4 --json` |
| ls | `board ls --project form-engine --stage building --json` |

`--actor` defaults to `BOARD_ACTOR`, then `user`. `--session` defaults to `BOARD_SESSION` and supplies the dispatch window unless `--window` is explicit. `--repo` aliases `--project`. Draft IDs also accept `draft:looper`; use that explicit form if a slug could be mistaken for a known bead prefix. `--epic-project` disambiguates the link target. Ticketed drafts remain addressable by both slug and beads epic ID.

`BOARD_URL` defaults to `http://127.0.0.1:4747`. Non-loopback URLs and redirects never receive the bearer token. HTTP retries are disabled. HTTP connect, receive, and pool waits are bounded; the direct DB connection has a one-second connect/query timeout and no supervisor restarts. Warnings do not include transport exception text or credentials.

When HTTP or authentication is unavailable, writes go directly to Postgres. `BOARD_DATABASE_URL` overrides `DATABASE_URL`; empty values are ignored. Otherwise the CLI reads `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE`, with the app's local development defaults. Set these to the same database as the deployed app. No local file holds queued events.

Replay takes committed pending rows in ID order under a database advisory lock. An applied or rejected row remains as a receipt. A missing project/entity or transient failure leaves the oldest row pending for a later boot/tick. A permanently unresolved row holds later rows pending; inspect `spooled_events.result`, `request`, and `state` rather than deleting authoritative records blindly.

## Decision requests (bb-zgd.1)

```sh
request=$(board ask decision bb-123 --question "Which layout?" \
  --option Wide --option Compact --recommendation Compact)
board wait "$request" --timeout 300
```

`ask decision <ticket-or-epic>` accepts `--question` (required), repeatable `--option`,
`--recommendation` (one of those options), repeatable `--option-detail "<option>=<what happens>"`,
`--text` (optional context), and repeatable
`--doc <path>` for the report, review or spec the question is about. Identity,
`--project`, actor and session flags work as above; use `draft:<slug>` for a draft.
Option details must name an offered option and contain nonblank text. The card shows each detail
under its option. Existing asks without details still work.

Cards show the ticket title, kind, nearest parent epic (or One-off), origin, and the
`What users see:` line from `## Summary`, when present. A Summary `Title:` replaces the ticket title.
Support Board ticket numbers and Asana links identify the origin; otherwise the card uses the
first sentence after removing Summary, headings, and `**Ticket:** none`. Bold markers are
removed; text longer than 80 characters ends with an ellipsis. Cards for a ticket stay together
under one heading.

Dispatch records the logical session name as well as `--window` (a window name or `%pane-id`).
Any caller can register this way. Cards use that record, or a board planning session, for
**Go to session**. The action selects the window and pane in the most recently active attached
client on the owning tmux server, using `FOREMAN_PLANNING_TMUX_SOCKET` or
`FOREMAN_EXTERNAL_TMUX_SOCKET` with the same defaults as SessionTmux. If focus fails (including
in preview), the card offers a command that switches clients inside tmux or attaches outside it.
A closed window shows a notice instead of a stale command. Unknown sessions show **Source unknown**.
Legacy pane records without a session name are used only when their harness matches the asker.

`foreman withdraw <request-id> --reason "Answered in chat"` withdraws a pending request.
Actor and session must match the original ask. Other states are refused. Withdrawal is recorded
with its reason, removes the card from Needs you, and appears in Recent outcomes. `foreman wait`
returns `state: withdrawn`. Agent/coordinator cards also have a Withdraw form; user cards do not.

`--doc` takes a Markdown file path: repo-relative, or absolute beneath a configured repo or
one of its git worktrees. A relative path that exists under the asker's working directory is
sent as its absolute path; otherwise it is read relative to the ticket's repo. The board
refuses the ask with `invalid_doc` when a path is outside every configured repo, missing, or
not Markdown (at most 20 per ask). Accepted paths are stored in the request facts as
`docs: [{repo, path}]` and shown on the card as links that open the document in the Needs you
side panel (modified clicks open `/documents/<repo>?path=…`).

Card text (the question, `--text`, chat questions, AskUserQuestion text, PR bodies) is
rendered as GitHub-flavoured Markdown with raw HTML omitted. A bare `.md` path in that text
(`slices/…/reviews/27-r1.md`, `docs/spec.md:12`, an absolute path under a configured repo)
becomes a document link when the file exists; relative paths are looked up in the card's repo
first, then the other configured repos. Long text shows its first lines and Show more. Each
card's ticket ID opens that ticket in the same side panel.
Success prints the UUID alone, or `{id,state}` with `--json`. No action kinds are enabled yet.

`wait <uuid>` always prints JSON. It polls every 500 ms until answered, declined,
withdrawn, superseded, done or failed. `--timeout` is nonnegative seconds (default 300);
zero performs one read. At timeout it prints the current request, including `state`,
`outcome` and `note`. A transport failure prints a JSON warning instead. HTTP calls
retain the existing bounded transport timeouts, so a deadline can overrun by one call.
Ask and wait always exit 0, including refusals and malformed input. Wait never spools.

The authenticated `/api/commands` envelope adds:

- `action: "ask"`, `id: <ticket-or-epic>`, `request_kind: "decision"`, `facts: {question,
  options, recommendation, text, docs, option_details}`, plus the existing identity and UUID fields.
  `option_details` maps option labels to text; `docs` is a list of path strings.
- `action: "wait"`, `id: <request-uuid>` returns the current request immediately;
  the CLI owns polling. It does not resolve ticket prefixes or force a beads read.

The ask's envelope UUID is also its durable request ID. An offline spool warning's
`request_id` can therefore be passed to `wait` after replay. Before replay it returns
`not_found`; a warning is not a successful ask. Replaying the same envelope creates
one request. Answers and declines are browser actions, not agent command verbs.
Withdrawal uses `action: "withdraw"`, `id: <request-uuid>`, `reason`, `actor`, and `session`,
plus a fresh envelope `request_id` for idempotent delivery.

## Card questions (fm-esh)

Ryan can use **Ask about this** on a pending card. The question goes to the registered
session as `[card question <request-id>] <text>`. A question does not answer the request.
Reply in the same card with either command:

```sh
foreman card-reply <request-id> --text "The check prevents a stale merge."
foreman card-reply <request-id> --body-file explanation.md
```

Use exactly one body option. Replies accept nonblank UTF-8 Markdown up to 20,000 bytes.
The author comes from `FOREMAN_ACTOR` and `FOREMAN_SESSION`, or the usual identity flags.
Unknown requests return `not_found`. Only pending requests accept messages; all other
states return `request_finished`. The thread remains visible in Recent outcomes.

The command envelope uses `action: "card_reply"`, `id: <request-uuid>`, `body`, `actor`,
and `session`, plus a fresh `request_id` for idempotent delivery. Body bytes travel in
the envelope. Replay does not read the file again. Success returns the message `id`
and the card's `request_id`; `--json` prints these fields. An offline warning is not
confirmation that a reply was stored.

Card questions accept up to 1,900 bytes. Delivery uses the existing guarded tmux
prompt writer. Claude needs an empty idle prompt. Pi uses pane input and needs an
empty editor in a running Pi process. No relay files are written. An unknown source,
closed pane, or busy prompt stores no question. The card shows the reason and a
copyable full question, plus the session command when a source is known. Failed
sends keep the text in the box; Try again clears the notice without clearing the text.
Session resume hooks do not close a card that has a question thread. A closed
session window or ticket completion still supersedes it, keeping the thread in
Recent outcomes. Ryan can also answer, decline, or withdraw it.

## Saved answers (fm-5fq)

```sh
foreman answer --question "Why is this card stale?" --body-file answer.md \
  --repo sample --ticket fm-1 --link docs/spec.md --link https://example.com
foreman answer --update <answer-uuid> --body-file revised-answer.md
```

`answer` stores a reference answer, not a reply to an approval request. It prints the
answer UUID and its `/answers?id=<uuid>` URL. `--json` prints `{id,url}`; the URL in
JSON is board-relative. `--actor` and `--session` use the normal environment defaults.
Question and a readable, nonempty UTF-8 body file are required for a new answer.
The file is limited to 1 MiB. Repo, ticket and up to 20 repeatable links are optional.
Paths are linked only when the document viewer can read them; HTTP(S) URLs are allowed.

An update adds a version. It requires the answer UUID and body file; omitted question,
repo, ticket and links carry forward. Author, session and time belong to each version.
The original version is never changed. Pin and archive are board actions. Archive hides
an answer from the default list; Show archived exposes it and Restore brings it back.
The page searches the latest question and body, and filters by exact repo and ticket.

The authenticated command envelope is:

```json
{"action":"answer","request_id":"<uuid>","update":null,"payload":{"question":"Why?","body":"Markdown bytes","actor":"pi","session":"build","repo":"sample","ticket":"fm-1","links":["docs/spec.md"]}}
```

For an update, `update` contains the answer UUID. The transport retains the existing
receipt and offline-spool behavior: a warning is not confirmation of storage. Replaying
the same request UUID creates one answer or one new version, not duplicates. Body bytes
are in the envelope, so replay does not need the original body file. Invalid input is
refused with a warning; malformed API payloads return 422 and unknown update IDs return 404.

## User setup

These are user steps, not actions performed by this build session.

1. Create the token file without overwriting an existing token:

   ```sh
   export BOARD_TOKEN_FILE="<a file in your secrets directory>"
   (umask 077; set -C; openssl rand -hex 32 > "$BOARD_TOKEN_FILE")
   chmod 600 "$BOARD_TOKEN_FILE"
   ```

   `BOARD_TOKEN_FILE` is required: there is no default path (house rule: no secret file path in tracked files); set it in an untracked env file such as the shell-local file and the units' runtime.env. The parent directory must already exist. Give the web process and CLI the same setting. The app never writes under `~/.ssh`. A missing file makes the API refuse requests and the CLI spool writes.

2. Apply the new migration to the app's database using the deployment's normal Mix environment and database configuration. Restart the worker so boot replay runs.

3. Build and install the escript yourself:

   ```sh
   MIX_ENV=dev mix escript.build
   install -m 755 board "$HOME/.local/bin/board"
   ```

   The destination directory must already exist. Erlang/OTP must be available. The executable is gitignored. Configure its Postgres connection to match the app before relying on offline delivery.

## Evidence

After coordinator verification, tests use the checkout-local default `beads_board_test_bb-cli`, with `MIX_TEST_PARTITION` appended when set. Browser acceptance uses the distinct `MIX_ENV=acceptance` database `beads_board_acceptance_bb-cli` on port 4759. The main checkout's port 4747 was not stopped or reconfigured. The acceptance server starts only the spool worker, not the beads reader. Scratch tickets come from a synthetic projection, not a beads store.

- [Workflow responses](../acceptance/bb-cli/workflow.json) record the real escript's commands, stages, exit codes, and refused history.
- Screenshots show the same connected page after [dispatch](../acceptance/bb-cli/dispatched.png), [progress](../acceptance/bb-cli/building.png), [report](../acceptance/bb-cli/reported.png), [review](../acceptance/bb-cli/in_review.png), and [commit](../acceptance/bb-cli/committed.png). The browser did not reload between transitions. The captures were inspected; the card moves between the expected columns without overflow or overlap.
- [Offline evidence](../acceptance/bb-cli/offline.json) records exit 0 and a pending row while the app was stopped, exit 0 with Postgres unreachable, and exactly one history event after two worker boots.
- `tools/cli-acceptance-server.exs`, `tools/cli-acceptance.cjs`, and `tools/cli-offline-acceptance.py` reproduce these checks using `MIX_ENV=acceptance` as documented in the README. The temporary server is stopped at handoff. Test credentials and process files remain only in gitignored `tmp/`.

The first test run used the shared test database before another session's migration made the conflict visible. Subsequent runs used isolated partitions. No production database was migrated. The first browser attempt failed origin validation in the test endpoint; the acceptance server now explicitly allows only its test origin.

## Review scope

Baseline `c41cd42b25dd7e193b4366eef7bcb4216f235acc` resolves to HEAD. The committed three-dot diff and commit list are empty. The requested self-review therefore covers the working tree and new files, excluding the coordinator-owned brief. Axes run sequentially in this session.

## Standards

Reviewed first against root/local AGENTS and the house baseline.

- Important, fixed: `CLITransport.deliver/2` initially expressed HTTP-to-spool delivery as branches. `Board.DeliveryMachine` now declares that lifecycle; `Board.SpoolMachine` declares pending/applied/rejected replay. Ticket and epic claims still go through their existing machines. Golden diagrams/matrices cover both new machines.
- Testing-order limitation: auth, claimed-event responses, forced sync, attachment persistence, CLI parsing, identity resolution, and spool replay had failing assertions before implementation. Initial HTTP transport tests were added after its implementation. The actual-escript Postgres-down regression failed before the linked-exit fix. This is not a complete TDD trail.
- OTP owns connection/process teardown; the adapters interpret effects. No application state is duplicated as UI state. JSON keys remain strings; no atoms are created from input. No dependency was added.

Declined to judge: pre-existing view styling and reader architecture; no changes to those contracts are intended. Standards implementation verdict: ready after the delivery-machine fix.

## Spec

Reviewed second against bb-c2w.7 and its attach/detach note, Decisions 3/7/8/11, acceptance 4/5, and design section 8 where the approved spec does not supersede it.

- Important, fixed: a board link to a draft disappeared from displayed membership after ticketing. `Initiatives.snapshot/1` now resolves stored draft identities to the linked beads epic. A regression failed before the fix and verifies detach through the beads identity too.
- Important, fixed: replay before config/first projection was ready treated unknown project resolution as a terminal rejection. It now leaves the event pending, preserving order until the project becomes available. The boot-order regression failed first.
- Important, fixed: malformed CLI input ignored `--json`. Usage and unexpected-error warnings now preserve JSON mode. The regression failed first.
- Every requested ticket and epic verb now has an HTTP-through-CLI integration check. Prefix resolution, longest containing cwd, explicit project, cross-repo links, show/list, JSON and exit codes are covered. API checks cover authentication, claimed-only events, effects/stage, invalid audit history and one forced read before 404.

Declined to judge: the older design's flat-file spool and app-created token (explicitly superseded); observed CR-link verbs (not part of this claim-only contract); skills wiring and deployment (later tickets). Verdict: ready after the fixes.

## Risk

Reviewed third: authentication, public API/CLI compatibility, boot ordering, transaction boundaries, connection supervision and replay concurrency.

- Critical, fixed: a failed linked Postgres connection could kill the real escript with exit 1 even though in-process transport tests returned zero. The subprocess regression reproduced this. The escript now traps linked exits; bounded connection teardown cannot propagate them. The rebuilt executable returns a one-line JSON warning and exit 0 with both services unreachable.
- Important, fixed: `epic ticket` without its required target returned 409, incorrectly telling agents this was an out-of-order claim; an unknown target could also hide the draft by linking it prematurely. The boundary now returns 422 for invalid target payloads and 404 after one forced read for a missing target, leaving the draft unchanged. A failing regression covers this.
- Important, fixed: approving a draft without `--spec` erased its existing spec link. The overlay now updates the link only when the payload includes that key. The regression failed first.
- The offline runner exposed empty database URL variables overriding valid PG settings. The CLI now treats empty values as unset, with a real-escript regression for the successful direct insert.
- The safety fact is transactional idempotency: the request UUID lock, claim effects, audit event and receipt commit together. Replay's terminal state commits in that same transaction. The committed HTTP-versus-replay race test proves one event and a repo-sync notification; replaying a lost HTTP response does not duplicate effects. Proof level 4 in tests, level 5 for stopped-app replay and the running browser workflow.
- Auth fails closed for missing/empty/wrong credentials; every API route uses the bearer plug. The CLI refuses non-loopback destinations and redirects, and replay still rejects observed events. No error output includes the token or database credentials.

Declined to judge: remote/multi-user security (localhost, same-user Postgres access is the boundary), killing the host Postgres service (a closed port exercises the same unavailable-connection path without disrupting other sessions), and long-running endurance. A permanently unresolved oldest spool row intentionally holds later rows pending to preserve replay order; terminal refusals are retained as rejected rows for inspection. No automatic data deletion or retention policy was added.

Verdict: ready after fixes. Cheapest integration gate: `MIX_TEST_PARTITION=_cli_unit mix precommit`; the browser runner checks the built escript and live updates.

## Initial gates

These were the initial handoff results. The coordinator correction and replacement gates below supersede the test-isolation claim.

All initial final commands exited 0:

```text
MIX_TEST_PARTITION=_cli_unit mix precommit
Repository hygiene: no license material or operator paths detected
Generated escript board with MIX_ENV=test
4 properties, 216 tests, 0 failures

NODE_PATH=<Playwright node_modules> node tools/cli-acceptance.cjs
PASS: escript dispatch/progress/report/review/commit; live card moved without reload;
409 exits 3 and is audited; no browser errors

python3 tools/cli-offline-acceptance.py
PASS: app stopped -> spooled/exit 0; Postgres unreachable -> warning/exit 0;
boot replay applies once across two restarts

git diff --check
clean
```

One intervening gate run at seed 423444 failed the existing `BoardWeb.InitiativesLiveTest` test "a late close callback cannot dismiss a different selected ticket" while LiveView verified its session token (`{:error, :invalid}`). The isolated test passed, and the entire suite passed with the same seed. No source change was made for that intermittent failure; its cause remains unproven. The final fresh `mix precommit` at seed 789334 passed with 4 properties, 216 tests, and zero failures.

The final application compile and gate emitted no warnings. Initial dependency compilation emitted the existing Oban unused-clause warning; no dependency code changed. `mix assets.build` completed before browser acceptance. The tests build the escript and execute it as a separate OS process, so the exit-code assertions do not rely only on an in-process return value.

Standards had one Important implementation finding, fixed, plus the disclosed TDD-order limitation. Spec had three Important findings, fixed. Risk had one Critical and two Important findings, fixed, plus the empty-URL regression. No open Critical or Important implementation finding remains.

Changed: the authenticated API, CLI, board-side links, and Postgres spool.
Verified: every requested verb, refusal/audit behavior, offline delivery, replay idempotency, live card movement, screenshots, and the final gate above.
Not verified: a user installation, real systemd deployment, a host-wide Postgres shutdown, or day-long endurance. No installation or production migration was performed. The unavailable-Postgres test uses a closed local port instead of stopping a shared service.

## Coordinator correction: hermetic test databases

The initial handoff did not establish a safe default for concurrent worktrees. I manually selected partitions, then used `_cli` for an acceptance server that explicitly switched the sandbox to `:auto` and left committed fixtures. That made my separate `_cli_unit` results look sufficient while the coordinator's test paths remained unsafe.

Reproduction before the fix:

- `MIX_TEST_PARTITION=_cli mix test` reproduced exactly **53 failures**. The database contained `board_config.source = "CLI acceptance"`, scratch tickets, history, and spool receipts from the earlier acceptance run.
- A newly created `_cli_repro_hermetic` partition passed all 216 tests and retained zero config, event, and spool rows. The 53 failures came from acceptance contamination, not an autonomous worker started by the unit-test application.
- All checkouts still defaulted to `beads_board_test`, explaining the competing migration histories and missing relations. The new database-name regression failed against that default before the change.

Corrections:

- `config/test.exs` derives the database from its checkout directory. The default here is `beads_board_test_bb-cli`; `_cli` now selects `beads_board_test_bb-cli_cli`. A regression loads identical configs from simulated `bb-cli` and `bb-merge` directories and verifies distinct names.
- `config/acceptance.exs` selects `beads_board_acceptance_<dirname>` with a normal connection pool. The acceptance server refuses `MIX_ENV=test` and no longer calls `Sandbox.mode(..., :auto)`. Both acceptance runners select the new database. Their browser and offline checks pass again against it.
- The test application still disables runtime scheduling, watching, and spool replay. A regression checks the actual named processes and role child list. The test that starts `SpoolWorker` explicitly uses its shared sandbox.
- `Board.TestDatabase.assert_clean!/0` checks all application tables and Oban jobs at suite startup and completion. It fails on committed fixtures instead of deleting them. A regression plants a config row, proves the guard fails, and proves the row remains for diagnosis.
- The direct-Postgres CLI integration tests register unique-ID cleanup before invoking the client. Cleanup now runs even if an assertion fails.
- README documents default names, partition suffixes, sandbox rules, and the separate acceptance environment. The existing runtime test's old hard-coded database expectation was updated after the first full rerun exposed it.

Prevention is structural plus a gate: acceptance cannot use the test environment, checkout defaults no longer collide, and committed-row leakage fails the suite. No lesson bead was created because this session still forbids bd commands. The coordinator can record this lesson from the evidence above.

Only this checkout's new default test database was dropped for the fresh-run gates. The old shared databases and other worktrees were not reset.

### Replacement final gates

After `MIX_ENV=test mix ecto.drop`, three consecutive plain `mix precommit` runs used `beads_board_test_bb-cli`. There was no reset or manual cleanup between runs. Every run passed both committed-row guards and repository hygiene with no warnings.

```text
Run 1, fresh database, seed 820195, exit 0
Finished in 22.9 seconds
4 properties, 221 tests, 0 failures

Run 2, same database, seed 119785, exit 0
Finished in 22.9 seconds
4 properties, 221 tests, 0 failures

Run 3, same database, seed 463422, exit 0
Finished in 22.8 seconds
4 properties, 221 tests, 0 failures
```

The coordinator's other entry point also passed against its newly named database:

```text
MIX_TEST_PARTITION=_cli mix test
seed 35880, exit 0
4 properties, 221 tests, 0 failures
```

A separate SQL check after the gates confirmed `current_database() = beads_board_test_bb-cli` and zero rows in `board_config`, `stage_events`, `spooled_events`, `agent_receipts`, and `oban_jobs`. The suite guard checks the remaining application tables too. `git diff --check` is clean.

The browser workflow and stopped-app/offline replay runners passed again using `beads_board_acceptance_bb-cli`. That server is stopped. No runtime writer was enabled in the unit-test application.

Follow-up review ran sequentially: Standards retains the SQL sandbox and supervised test-process ownership; Spec covers checkout defaults, suffixes, README, and three fresh/repeated gates; Risk checks committed cleanup and separation from acceptance data. No open Critical or Important finding remains for this correction. The earlier intermittent LiveView token failure did not recur in these runs; its underlying cause is still unproven.
