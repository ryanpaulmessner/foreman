# Foreman previews

Once foreman is registered in devserve, run `devserve up` from a worktree. The
registration uses ports 4840–4899, `data = "fresh"`, and these command arrays:

- Start: `["/usr/bin/python3", "bin/devserve.py", "start"]`
- Migrate: `["/usr/bin/python3", "bin/devserve.py", "migrate"]`
- Seed: `["/usr/bin/python3", "bin/devserve.py", "seed"]`

The wrapper requires devserve's database name for this worktree and an assigned
port in that range. It refuses missing settings rather than falling back to
`foreman_dev`. Migrate compiles first, including dependencies in a new worktree.

Fresh mode runs the existing `priv/repo/seeds.exs`, which leaves an empty board.
It never copies live sessions, requests, credentials or queued jobs. Feature
walkthroughs supply their own seed data against the preview database.

All three commands run with `FOREMAN_ROLE=web` and `PREVIEW=0`, so UI actions are
available but worker processes and Oban queues are disabled. Configuration,
discovery and Pi sessions use `tmp/devserve/` in the worktree. Both tmux socket
settings use a worktree-specific `fm-preview-<hash>` name, never the live sockets.

The wrapper discards inherited board credentials and adds `bin/preview-stubs`
before tool directories on PATH. Both stubs refuse execution. Session launchers
resolve the executable to an absolute path before starting a shell. Erlang/asdf
may prepend runtime directories during boot; agent resolution must still select
these stubs. This is an isolated development setup, not a sandbox for untrusted code.

Remove the preview with `devserve down <unit> --drop-db`. Run wrapper tests with
`python3 -B -m unittest discover -s test/scripts`; `mix precommit` also runs them.
