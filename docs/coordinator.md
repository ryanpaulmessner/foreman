# Coordinator session

Run `foreman coordinator` in the coordinator pane on the board's tmux server. The web service must be available and authenticated CLI configuration must already work.

- No recorded conversation: launch Claude with a new `--session-id`.
- Recorded conversation: launch with `--resume`.
- `foreman coordinator --fresh`: replace the recorded conversation.
- `foreman coordinator --adopt <uuid>`: record an existing conversation without launching it. This command does not need tmux.

Stop the running coordinator before replacing or adopting its conversation. The board's Focus control selects its window; Relaunch resumes it; Start fresh requires confirmation.

The service replaces only the requesting pane, after checking its socket and its `coordinator` tmux session. Claude runs in `~/dev/music`, with `/orient` as the only prompt and the existing per-launch hooks. The service PATH must contain `claude`. No global Claude settings change.

Pane startup uses the tmux server/session environment, not the web service's client environment. The wrapper starts `$SHELL` as an interactive login shell, removes service settings before Claude, and returns to `$SHELL` when Claude exits. Per-launch hooks carry their URL and token explicitly and resolve `foreman` on the pane PATH. Coordinator respawns disable automatic renaming before replacing the pane, preserving the layout's window name.

The singleton uses the reserved system key `__foreman__/coordinator` in the existing session table. It has no ticket overlay or configured project. Only session-waiting requests use that system subject; ordinary approvals still need tickets. Idle time never parks this session. A missing window becomes `ended`, preserving its conversation ID.

When this session or a board-launched planning session finishes a turn (Claude's Stop hook), it is recorded as `waiting`, but nothing goes to Needs you. The Stop also supersedes that session's pending idle and usage-limit requests; question and permission requests stay open, since a background agent's prompt can outlive the main turn. AskUserQuestion, other permission requests and usage limits still raise a request, which clears when the session resumes. While no request is pending, any hook activity returns the session to `running`. External and pi sessions raise a request every time they wait.

## Verification notes

`FOREMAN_HOST_ACCEPTANCE=1 mix test test/foreman/pane_environment_test.exs` checks the real login environment on a clean foreground scratch server. Without that flag, the test uses a fixture shell and tools. Both use stub Claude and a local ticket fixture.

`test/foreman/coordinator_integration_test.exs` runs the built escript against an isolated HTTP endpoint and scratch tmux server, with a stub Claude executable. It verifies argv, working directory, identity persistence, Focus/Relaunch, Needs you and Continue. No real Claude account is used.

Tmux takes pane PATH from the connecting client even when its global environment is clean. The adapter clears the client environment and uses `new-session -E` to keep that empty client from masking server values such as `SSH_AUTH_SOCK` and `DISPLAY`. It forces UTF-8 (`-u`); without a UTF-8 client locale, tmux 3.4 replaces tabs in formatted output with underscores. Shell startup files can reintroduce service settings, so the wrapper removes them after startup as well.

Tmux distinguishes socket names (`-L`) from socket paths (`-S`). The CLI's `TMUX` variable contains the latter. A new-window target needs the trailing colon (`=coordinator:`) when session and window names coincide; otherwise tmux can interpret it as occupied window zero.
