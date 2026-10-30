# Bound the board log on macOS

Install after merge, with Ryan's approval. These steps change the running service.
The build session must not run them.

1. Stop the launchd board agent and its restart loop.
2. Move the old `board.log` out of the log directory. Archive or delete it with Ryan's approval.
   Remove old numbered copies if present. The wrapper does not trim old archives.
3. Install `board-log.py` beside the existing board wrapper. Use an absolute Python 3 path.
4. In the existing wrapper, keep its PATH, environment, checkout and restart loop.
   Replace only the foreground server command with:

   ```sh
   /absolute/path/to/python3 /absolute/path/to/board-log.py \
     "$HOME/Library/Logs/foreman/board.log" mix phx.server
   ```

   For a release, replace `mix phx.server` with the release's `bin/foreman start` command.
   Do not append `>> board.log 2>&1`: the Python wrapper owns that file.
5. Remove any launchd stdout/stderr paths that point at `board.log`. Send wrapper diagnostics
   to `/dev/null` or a separately managed log. Only one wrapper may write this log.
6. Start the agent. Check the page and the log. Check that the server stops with the agent.

The wrapper combines stdout and stderr. It retains the active file plus four archives,
`board.log.1` through `board.log.4`, each at most 50 MiB (250 MiB total).
It forwards stop signals to the child process group and returns the child's exit code.
Both dev (the current board mode) and prod use Logger level `info`.
No Python packages are required. Rotation tests use temporary files, not the board log.
