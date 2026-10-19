# foreman

Source: [rpmessner/foreman](https://github.com/rpmessner/foreman).

A local board for every beads repo on this machine, organised around epics.
The worker reads configured repos through Oban and keeps a droppable Postgres
projection. Settings shows config validation, sync health, columns and discovered
repos using Fluxon 3. Initiatives, ticket/epic workflows and the agent CLI remain
later slices; `/` currently opens Settings.

- [Approved MVP spec](docs/spec.md) is authoritative.
- [Design](docs/design.md) records the design pass and rationale.
- `docs/mockup/` contains the approved epic-first design canvas.
- [FSM build report](docs/sessions/bb-fsm.md) documents the DSL and compile checks.

## Check the scaffold and DSL

```sh
mix deps.get
mix precommit
MIX_ENV=test mix foreman.fsm.docs
```

`mix test` and `mix precommit` create and migrate a checkout-local database on
local Postgres: `foreman_test_<checkout directory name>`. For example, the
`bb-cli` and `bb-merge` worktrees use `foreman_test_bb-cli` and
`foreman_test_bb-merge`. The name comes from the config file's directory, not
the shell's working directory. `MIX_TEST_PARTITION` is appended unchanged:
`MIX_TEST_PARTITION=_cli` in `bb-cli` uses `foreman_test_bb-cli_cli`.
Use distinct checkout directory names for concurrent worktrees.

Database tests use the SQL sandbox. Repo and manual-mode Oban start, but the
runtime scheduler, config watcher, and spool worker do not. Tests that start a
worker explicitly share their sandbox with it. Direct-Postgres CLI tests
register cleanup before writing. The suite checks for leaked committed rows
before and after the run and fails rather than silently clearing them.

Live CLI acceptance uses `MIX_ENV=acceptance` and the separate
`foreman_acceptance_<checkout directory name>` database with a normal pool.
The acceptance script refuses to run under `MIX_ENV=test`; it never changes the
test sandbox to automatic mode. Prepare and start it with:

```sh
mkdir -p tmp
(umask 077; set -C; openssl rand -hex 32 > tmp/cli-token)
MIX_ENV=acceptance mix ecto.create
MIX_ENV=acceptance mix ecto.migrate
MIX_ENV=acceptance FOREMAN_ROLE=web PORT=4759 PHX_SERVER=true \
  FOREMAN_TOKEN_FILE="$PWD/tmp/cli-token" \
  mix run --no-halt tools/cli-acceptance-server.exs
```

The [CLI report](docs/sessions/bb-cli.md) records the original contract using the
old names. Current CLI setup:

```sh
mix escript.build
install -m 755 foreman "$HOME/.local/bin/foreman"
```

Use `FOREMAN_TOKEN_FILE` (no default; the same token file as the web service),
`FOREMAN_URL` (default `http://127.0.0.1:4747`), `FOREMAN_ACTOR` (default `user`),
and `FOREMAN_SESSION`. Offline delivery uses `FOREMAN_DATABASE_URL`, then
`DATABASE_URL`, then standard `PG*` settings; point these at the deployed database.
Store credentials only in untracked environment files.
The browser and offline acceptance scripts select this same acceptance database.
They do not use `MIX_TEST_PARTITION`, seed a unit-test database, or start a beads reader.
`Foreman.Stage` is the production pure machine; its persistence effects are not wired yet.
Epic remains a test fixture. Generated docs live in `docs/machines/` and tests compare them byte-for-byte.
Elixir 1.19 scans both `.ex` and `.exs` under `test/`; manually loaded fixture files outside `test/support/` use the `_helper.exs` suffix to avoid discovery warnings.

To run the Phoenix scaffold with Postgres, configure `config/dev.exs`, then run `mix setup` and `mix phx.server`.
Development uses `foreman_dev` and listens on `127.0.0.1:4747` (`PORT` overrides
the port, not the loopback bind). Migrate before starting Oban. Production still
requires `DATABASE_URL`, plus `SECRET_KEY_BASE` for web/all; no systemd unit is installed.

## Worktree previews

With `PREVIEW=1`, foreman serves the copied Postgres cache without starting
workers or executing queued jobs. Repo, the Postgres notifier, and the selected
role's web endpoint stay available. Config discovery, beads/files readers, forge
sync, session monitoring, spool consumption, and preview polling stay off.

For reader development, set `FOREMAN_PREVIEW_READERS=1` in the preview app's
startup environment and restart it. This restores the selected role's full worker
set and queues; it does not override `FOREMAN_ROLE=web` or the test runtime switch.
The `PREVIEW=1` external-write guard still refuses writes. Leave the opt-in unset
for UI work; copied sync and session status will remain a snapshot.

## Install the user services

These steps are for you to run on the host. Nothing in the build installs or
starts services. The templates are in [`deploy/systemd/`](deploy/systemd/).
They use one release at `~/.local/lib/foreman/current`, two foreground BEAM
processes, and no terminal or Erlang distribution. Board-launched planning sessions
use a separate, optional [foreman-tmux service](deploy/systemd/README.md); install
that service before using Launch, and never restart it during app deployment.

### Prepare the host and environment

Use a Linux host with systemd user services, Postgres 16, `python3`, `inotifywait`,
and the tested embedded-store `bd` available. On WSL, enable systemd in the
host's WSL configuration first. Start the host's Postgres service and create the
`foreman` database with a dedicated database user. Do not run the release as
root. Run `command -v bd python3 inotifywait` to find the executable directories.

```sh
install -d -m 700 "$HOME/.config/foreman"
install -m 600 deploy/systemd/runtime.env.example "$HOME/.config/foreman/runtime.env"
install -m 600 deploy/systemd/web.env.example "$HOME/.config/foreman/web.env"
mix phx.gen.secret
```

Edit both files before continuing. Set `DATABASE_URL` and an **absolute** `PATH`
containing `bd`, `python3`, and `inotifywait` in `runtime.env`. Put the generated
secret only in `web.env`. These are systemd environment files: no `export`,
`$HOME`, `~`, or command substitutions. URL-encode database credentials as needed.
Keep both files untracked, mode 0600, outside a symlink into tracked dotfiles.
Do not put Fluxon credentials in either file; they are build-time only.
The API token belongs to the later API ticket, not these environment files.

The units do not read shell startup files. `FOREMAN_ROLE`, `PHX_SERVER`,
`RELEASE_DISTRIBUTION`, and `RELEASE_TMP` belong to the units; do not override them
in environment files. The worker explicitly removes the endpoint secret and
both units remove Fluxon variables inherited from the user manager.

### Build, migrate and enable

Build on the same OS and architecture as the host, with your existing private
Hex authentication and Fluxon build variables available in your shell:

```sh
mix deps.get
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite

release_id=$(date -u +%Y%m%dT%H%M%S)
install -d -m 700 "$HOME/.local/lib/foreman/releases"
cp -a _build/prod/rel/foreman "$HOME/.local/lib/foreman/releases/$release_id"
ln -s "releases/$release_id" "$HOME/.local/lib/foreman/current"
```

Migrate before starting either service. Supply `DATABASE_URL` in the migration
shell without adding it to shell history. The following hidden prompt works in
Bash. Do not `source` systemd environment files; they are not shell scripts.

```bash
read -r -s -p 'DATABASE_URL: ' DATABASE_URL; printf '\n'
export DATABASE_URL
(umask 077
 FOREMAN_ROLE=worker RELEASE_DISTRIBUTION=none \
   "$HOME/.local/lib/foreman/current/bin/foreman" eval \
   '{:ok, _, _} = Ecto.Migrator.with_repo(Foreman.Repo, &Ecto.Migrator.run(&1, :up, all: true))')
migration_status=$?
unset DATABASE_URL
test "$migration_status" -eq 0
```

Continue only if the migration succeeded. Then install and enable the units:

```sh
install -d "$HOME/.config/systemd/user"
cp deploy/systemd/foreman-web.service deploy/systemd/foreman-worker.service "$HOME/.config/systemd/user/"
systemd-analyze --user verify "$HOME/.config/systemd/user/"foreman-*.service
systemctl --user daemon-reload
systemctl --user enable --now foreman-worker.service foreman-web.service
```

Open `http://127.0.0.1:4747/settings`. Configure repositories using the TOML section
below. A fresh installation has no repositories enabled.

Both units start at login through `default.target`. To keep the user manager
running after logout and start it at host boot, you may enable lingering with
`loginctl enable-linger "$USER"` (host policy may require an administrator).
On WSL, the distro must itself be running; these units cannot launch a stopped
distro. Start the distro and user session before agents.

System and user managers have separate dependency graphs. A user unit cannot
order after the system manager's `postgresql.service`; adding that name would
refer to a different user unit. These templates therefore retry independently.
If your host exposes a real Postgres readiness unit in the **user** manager,
add `After=` for that unit in user drop-ins. Do not move Postgres into this release.
`Restart=always`, a five-second delay, and disabled start-rate limiting allow
recovery after boot failures. Database connections also reconnect after outages.

### Update the release

Build a new release and copy it into a new timestamped directory using the build
commands above, but do not repeat the initial `ln -s`. Never overwrite the release
files a running service uses. Back up Postgres before schema changes.

```sh
systemctl --user stop foreman-worker.service foreman-web.service
ln -s "releases/$release_id" "$HOME/.local/lib/foreman/current.next"
mv -Tf "$HOME/.local/lib/foreman/current.next" "$HOME/.local/lib/foreman/current"
```

Run the migration command above against the new `current`. If it fails, leave
both services stopped and investigate. Restore an older release only if its code
is compatible with the database schema. Refresh the unit templates if changed:

```sh
cp deploy/systemd/foreman-web.service deploy/systemd/foreman-worker.service "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user start foreman-worker.service foreman-web.service
```

Use `systemctl --user restart foreman-worker foreman-web` after changing
environment files. TOML edits hot-reload without a restart. Stop uses SIGTERM on
the BEAM first, allowing Oban and its owned subprocesses to drain. After 90 seconds,
systemd kills remaining processes in that service's cgroup. Explicit stops do not
trigger `Restart=always`. Use systemctl, not release `stop` or `rpc`, because
Erlang distribution is disabled.

### Inspect logs and verify host recovery

```sh
systemctl --user status foreman-web foreman-worker
journalctl --user -u foreman-web -u foreman-worker -f
systemctl --user is-enabled foreman-web foreman-worker
```

After installation, test recovery when no reads or writes are in progress:
record each service's `MainPID` with `systemctl --user show -p MainPID`, kill only
its main process with `systemctl --user kill --kill-whom=main --signal=SIGKILL
foreman-web`, and check that it returns with a new PID. Repeat for the worker.
Check the page and a repository sync afterward. Restart WSL at a safe time, open
the distro again, and check both units and the page before starting agents.
These host checks cannot be proved by a build-only smoke test.

### Uninstall the services

```sh
systemctl --user disable --now foreman-web.service foreman-worker.service
/usr/bin/rm "$HOME/.config/systemd/user/foreman-web.service" \
  "$HOME/.config/systemd/user/foreman-worker.service"
systemctl --user daemon-reload
systemctl --user reset-failed
```

Keep the database, TOML, environment files, and release directories until you
choose to remove them. Remove service drop-ins too if you added any. Do not disable
lingering if other user services need it. Uninstall does not drop Postgres data.

### Migrating from beads-board

The coordinator performs this host cutover; the repository build does not:

1. Back up Postgres and record stage, session and history counts. Stop and disable
   `beads-board-web` and `beads-board-worker` before starting either new unit.
2. With all old database clients stopped, rename database `beads_board` to `foreman`
   in place. Keep the existing tables and applied migrations; do not recreate data.
3. Move `~/.config/beads-board` to `~/.config/foreman`; rename `board.toml` and
   `board.local.toml` to `foreman.toml` and `foreman.local.toml`. Keep the `[board]`
   TOML table unchanged. Rename `BOARD_*` environment settings to `FOREMAN_*` in
   runtime and shell-local files; update database URLs to the renamed database.
   Standard `DATABASE_URL`, `PG*`, `PHX_*` and release variables keep their names.
4. Move the checkout and update its remote to `rpmessner/foreman`. Build and install
   the new release under `~/.local/lib/foreman` and the `foreman` escript as above.
   Update callers and the external skills repo. Remove the obsolete `board` CLI
   only after its callers have moved over.
5. Install the new `foreman-web` / `foreman-worker` units, remove the old unit files
   and obsolete drop-ins, run `systemctl --user daemon-reload`, and enable/start
   the new units. Do not run old and new workers together. Pending Oban jobs store
   module names: inspect/drain old `Board.*` jobs before cutover, or explicitly
   remap their worker names to `Foreman.*` while stopped before replaying them.
6. Verify both services, sync, CLI delivery and the recorded data counts before
   removing old release directories. Browser sessions/filter preferences may reset
   because their application namespace changed.

### Run the release smoke test without installing

After building the release, run `python3 tools/release-smoke.py`. It uses the
local test Postgres credentials to create a unique disposable test database,
starts the actual `bin/foreman start` twice on non-default ports, verifies role
children, HTTP and Postgres sync notification delivery, then sends SIGTERM and
requires exit 0 from both. It drops its database afterward. Logs and generated
runtime files stay in the checkout's ignored `tmp/release-smoke-*` directory.
The exporter is a synthetic fixture executable, not the host's `bd`; the test
never opens a real store. Real embedded-store safety remains covered by the
[reader acceptance report](docs/sessions/bb-exec.md).

## Deployment roles and notifications

One release supports two systemd user services, `foreman-web` and
`foreman-worker`, without Erlang clustering. Set `FOREMAN_ROLE=web` in the web
unit and `FOREMAN_ROLE=worker` in the worker unit. Both use the same database and
Oban schema prefix. Set `RELEASE_DISTRIBUTION=none` in both release units.
`FOREMAN_ROLE=all` is the default for development and tests; unknown values fail boot.
Role and code changes require a service restart; only TOML configuration is
hot-reloaded. Do not use development code reloading as a worker deployment path.

- Web starts Phoenix and a queue-less Oban instance for Postgres notifications.
  It disables Oban plugins and leadership. It must not start readers or watchers.
- Worker starts Oban queues, the nominal scheduler and config directory watcher,
  but no Phoenix endpoint. Runtime readers are disabled in the test environment.
- Both start Repo. Phoenix.PubSub remains for endpoint internals, not cross-role
  product events. DNS clustering is not started.

`Foreman.Events` publishes versioned `config_changed`, `sync_status_changed`, and
`projection_changed` invalidations through `Oban.Notifiers.Postgres`. Subscribers
receive `{:notification, :foreman_events, payload}`. Changed projection transactions
publish at commit; unchanged export hashes publish nothing. A rolled-back
transaction cannot notify. Tests exercise independent notifiers and a raw
Postgres LISTEN connection, not an in-memory notifier replacement.

Notifications are transient. Settings fetches Postgres on mount and every three
seconds to recover missed notifications. Config installation and validation are
persisted before publication. `Foreman.Runtime.ping/1` sends a `sync_requested`
notification across roles; it uses the same admission path as ticks and sweeps.
Release packaging and installed systemd units remain later work.

## Export projection boundary

`Foreman.Beads.Export.decode/1` validates a complete JSONL export, keeps raw fields,
and normalizes known enums through explicit tables. Unknown enum strings become
`{:unknown, value}`. Bad records reject the entire export, never a partial snapshot.
`Foreman.Beads.Projection.replace/2` takes a repo key and successful export bytes;
call it only after the reader has checked the command's exit status. It hashes
bytes and skips all projection writes for an unchanged hash. Changed exports
replace that repo's JSONB bead rows in a transaction. Embedded comments and edges
remain in `raw`; separate indexed edge/comment tables are not needed yet.

The `tickets` table reserves the overlay identity and stage fields. Projection
replacement marks missing tickets orphaned and clears the marker on reappearance,
without changing stages or deleting facts. Stage backfill remains unimplemented.
To rebuild the cache, delete its `bead_repos` row (cascading to `beads`), not only
its bead rows; the hash belongs to that same cache. Overlay rows have no cache FK.

`Foreman.Beads.JournalLock.check/2` passively matches journal device/inode against
Linux `/proc/locks`. Missing, unreadable or ambiguous evidence defers the read.
It never acquires a store lock. `SyncJob` executes this check before each export.
The probe's [read rule](docs/probe-bd-concurrency.md) remains mandatory.

Oban 2.23.0 emits an unused MySQL-pattern compiler warning on Elixir 1.19 when
MyXQL is absent. The required pin is retained without suppressing the warning or
adding an unused database driver. App compilation and precommit can be checked
independently; a fresh dependency build still has this upstream warning. The
coordinator accepted this pinned-dependency warning; application code must still
compile with zero warnings.

`Foreman.Beads.Read` and `Schedule` now define the pure read/admission protocols,
with declared machines and generated goldens. Read timeout retains admission
until the owned subprocess is reaped and discards late stdout. Schedule accepts
three-second ticks even without changed signals, coalesces busy requests, and
never launches catch-up reads on completion. Tokens include an owner epoch and
generation so stale completions cannot release a newer flight. These modules
perform no IO. `Runtime` executes schedule effects; `SyncJob` executes read effects.
Physical aliases share a catalog identity and one scheduled export, projected to
all their configured keys. Postgres advisory admission plus a Linux abstract
socket prevent concurrent exports across workers, including the BEAM-death/reap
window. Neither lock touches the store or creates a file.

The bundled Python guardian owns a fresh process group, enforces a 20-second
limit and 32 MB stdout cap, kills only its group, and reaps before replying.
Owner/port death cancels it; partial or timed-out output never projects. Linux,
Python 3, `realpath`, `inotifywait`, and the tested bd binary must be on the service
PATH. Embedded-only reads reject redirects, ambiguous locks and server mode;
there is no repair, store copy, JSONL fallback or Dolt-server startup.

Every enabled physical store gets a nominal three-second request even without a
changed signal. This replaces the insufficient signal-only heuristic, rather
than watching Dolt files that exports themselves modify. Five-minute sweeps and
pings coalesce; completion never queues catch-up work. Unchanged exports make no
projection or health writes (unless health is recovering). Oban's own job records
still change. Settings labels snapshot age separately from health; it does not
pretend an unchanged snapshot was freshly written.

## Config contract

The worker reads `~/.config/foreman/foreman.toml`, then
`foreman.local.toml` beside it, over `priv/foreman.defaults.toml`. The app never writes
these files. No user files are needed to run the tests; they use temporary directories.
`FOREMAN_CONFIG_DIR` overrides the directory for isolated runs; `FOREMAN_DISCOVERY_ROOT`
overrides the default `~/dev` discovery root. Non-recursive directory notifications handle
atomic editor saves; a 30-second reconciliation recovers missed notifications.
If the config directory is absent, the watcher follows its nearest existing
parent and moves to the config directory when it appears.
Discovery skips symlinks and build/dependency trees and is bounded to eight levels.
No home config is created. Accepted config, last error, load time and physical
store catalog live in Postgres so web-only nodes need no filesystem access.

```toml
[board]
swimlanes = "project" # project | epic | none
stale_session_after = "2h" # positive integer with s, m, h, or d
terminal_app = "Ghostty" # macOS app Open session brings to the front (default Ghostty)

[[repos]]
key = "sample"
path = "~/dev/sample"
github = "example/sample" # optional
forge = "github" # github | none; inferred from github if omitted
tickets = "beads" # beads (default) | files
color = "violet"
enabled = true

[[columns]]
title = "Working"
stages = ["dispatched", "building"]
collapsed = false

[backfill]
closed = "done"
default = "queued"

[epics."sample-123"]
pin = true
collapse = false
color = "violet"
```

With `tickets = "files"`, the worker watches the main checkout's `tickets/`
directory using non-recursive inotify and rescans every 60 seconds. Hand edits and
CLI rename saves are coalesced into stable snapshots. Malformed files retain their
last good cached version; Settings names the file and error. File tickets reuse the
existing repo/id identity, preserving stages, sessions, links and requests.
A CLI write/recovery lock retains the cache and retries; the reader never removes
that lock. Replacing the entire directory recovers on the periodic rescan.

Tables merge recursively. A supplied `columns` array replaces all inherited
columns. Repo entries merge by `key`, preserving order; a local entry can contain
only `key` and `enabled = false`. `repos = []` clears the inherited list. Defaults
ship **no repos**, so a fresh install never opens a store without configuration.
Missing user files are optional; unreadable files, malformed TOML, unknown options,
duplicate keys/expanded paths, and unknown ticket stages are errors. Paths must be
absolute or start with `~/`; no environment-variable expansion occurs. Path
validation does not open or resolve repository stores or symlinks.

`Foreman.Config.load(directory)` returns `{:ok, config}` or `{:error, message}`.
All keys and configured enum values remain strings. `Foreman.Config.parse_layers/2`
accepts named TOML contents for pure tests. Validation uses `Foreman.Stage`'s declared
states, not an independent stage list.

`Foreman.Config.Reload` holds the last good config through its declared machine.
Its read/broadcast effects are data, not executed callbacks. The runtime must run
reads through Oban and supply every terminal result, including job failure, before
another reload can start. Bad edits retain the previous config and expose an error.
`ReloadJob` executes this contract transactionally. Worker restarts enqueue a new
reload; a failed job cannot leave an in-memory reload stuck in loading. The
previous persisted config survives. A shared row lock at projection commit
rejects late results for removed, disabled or repointed config entries.

## Scratch acceptance

Only run these with permission to write scratch copies. They never open original
stores with bd. Server-mode acceptance uses copied metadata, not live PID/port files.

```sh
python3 tools/prepare-foreman-acceptance.py
FOREMAN_CONFIG_DIR=/tmp/bb-exec/config FOREMAN_DISCOVERY_ROOT=/tmp/bb-exec/repos mix phx.server
# In another shell, with the board running:
python3 tools/foreman-write-acceptance.py
python3 tools/verify-foreman-acceptance.py
```

The writer runs for ten minutes, without retrying failed writes. Verification
compares `bd list --json --all --limit 0`, checks persisted notes/dependencies and
measures idle note freshness. Raw artifacts stay under `/tmp/bb-exec`; see
[the session report](docs/sessions/bb-exec.md) for measured evidence. The harness
uses `psql -X` to ignore personal psql settings. Python bytecode caching is disabled
because embedded operator paths in `.pyc` files correctly fail the hygiene gate.

Fluxon is fetched from the preconfigured private Hex repo. Keep its authentication
and `FLUXON_LICENSE_KEY` / `FLUXON_KEY_FINGERPRINT` in the environment, never here.
The CSS theme and JS hooks are bundled through app.css/app.js, with no CDN scripts.

## Repository hygiene

`mix precommit` runs `mix foreman.hygiene` over tracked and nonignored untracked
files. The guard rejects local operator paths, literal Fluxon license assignments,
and exact license environment values when present. It reports categories only,
never matching content or secret paths. It does not read credential files.
Without those environment values, unlabelled license blobs cannot be identified
reliably; the guard is a safety net, not a general secret detector. Never put
license material into the repository, including ignored files.
