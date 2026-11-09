defmodule Foreman.SessionLaunch do
  @moduledoc """
  Starts the agent of a session the board did not launch itself (spec Decisions 17 and 20):
  Resume opens the row's own conversation again (Claude `--resume <id>`, Pi
  `--session-id <id>`, in its workdir), and Start fresh opens a new Claude conversation
  for a coordinator. Board-launched coordinators resume through `Foreman.Sessions`.

  Where the pane opens (Decision 20): a Pi build whose coordinator is live gets a new pane
  in the coordinator's window, tagged `@build <name>` as `pi-window --pane` does; every
  other session gets a new window with its name, in the tmux session of its live
  coordinator, else the project's session (`board.tmux_session`, else the row's project,
  else `coordinator`), on the server where it ran. Every tmux call uses `-N`, so no call
  starts a tmux server.

  The agent runs under the user's login shell, with the service settings removed and
  `FOREMAN_ACTOR`, `FOREMAN_SESSION`, `FOREMAN_PARENT` and `FOREMAN_TICKETS` set as
  `pi-window` sets them. The executable is the absolute path found on the board's PATH
  (option `:executables`, a map from harness to a name or path, for tests and stubs).

  Options: `:runner` (a `System.cmd/3` stand-in), `:executables` and `:prompt` (the
  agent's first message, one line).
  """
  alias Foreman.{AgentSession, AgentSessions, SessionPane, SessionTargets}

  @doc """
  Opens `row`'s own conversation again in a new pane. Returns `{:ok, pane_id}` or
  `{:error, reason}`: `:workdir_gone`, `:still_open` (the row's old pane is still listed),
  `:pi_unavailable`, `:claude_unavailable`, `:tmux_unavailable` or `"refused in preview"`.
  """
  def resume(%AgentSession{conversation_id: id} = row, opts \\ []) when is_binary(id) do
    args =
      case row.harness do
        "pi" -> if(opts[:model_resume], do: model(row), else: []) ++ ["--session-id", id]
        "claude" -> model(row) ++ ["--resume", id]
      end

    args =
      if row.harness == "claude" and opts[:model_resume] do
        case Foreman.Repo.get(Foreman.PlanningSession, row.id) do
          nil ->
            args

          planning ->
            args ++ ["--settings", Jason.encode!(Foreman.SessionHooks.settings(planning, opts))]
        end
      else
        args
      end

    open(row, args, opts)
  end

  @doc """
  Opens a new Claude conversation `conversation_id` for coordinator `row`, which starts
  with `/orient`. Returns `{:ok, pane_id}` or `{:error, reason}`.
  """
  def fresh(%AgentSession{} = row, conversation_id, opts \\ []) do
    open(
      %{row | harness: "claude"},
      model(row) ++ ["--session-id", conversation_id],
      Keyword.put_new(opts, :prompt, "/orient")
    )
  end

  defp model(%{model: model}) when is_binary(model) and model != "", do: ["--model", model]
  defp model(_), do: []

  defp open(row, args, opts) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, executable} <- executable(row.harness, opts),
         true <- (is_binary(row.workdir) and File.dir?(row.workdir)) || {:error, :workdir_gone},
         socket = SessionPane.socket(row.tmux_server),
         {:ok, panes} <- SessionTargets.list(Keyword.put(opts, :socket, socket)),
         # The old pane still listed means the agent may still run: never a second one.
         false <- Enum.any?(panes, &(&1.pane == row.pane_id)) && {:error, :still_open} do
      prompt = if is_binary(opts[:prompt]), do: [opts[:prompt]], else: []
      command = command(row, [executable | args ++ prompt])

      with {:ok, pane} <- place(row, panes, socket, command, opts) do
        if row.tmux_server == "board" do
          case tmux(socket, ["set-option", "-w", "-t", pane, "@foreman-session", row.id], opts) do
            {:ok, _} -> {:ok, pane}
            {:error, reason} -> {:error, {:opened, pane, reason}}
          end
        else
          {:ok, pane}
        end
      end
    end
  end

  @doc "Checks the harness executable before an existing process is stopped."
  def executable(harness, opts) do
    name = Map.get(Keyword.get(opts, :executables, %{}), harness, harness)

    case System.find_executable(name) do
      nil -> {:error, if(harness == "pi", do: :pi_unavailable, else: :claude_unavailable)}
      path -> {:ok, path}
    end
  end

  # Decision 20: a Pi build next to its live coordinator, else a window of its own.
  defp place(row, panes, socket, command, opts) do
    parent = parent_pane(row, panes)

    if row.kind == "build" and row.harness == "pi" and parent do
      with {:ok, pane} <-
             tmux(socket, split(parent.pane, row.workdir, command), opts),
           pane = String.trim(pane) do
        # The tag is how `pi-wait --pane` and the coordinator find the build.
        tmux(socket, ["set-option", "-p", "-t", pane, "@build", row.name], opts)
        tmux(socket, ~w(select-pane -t) ++ [pane, "-T", row.name], opts)
        tmux(socket, ~w(select-layout -t) ++ [parent.pane, "tiled"], opts)
        checked(pane)
      end
    else
      session = (parent && parent.session) || project_session(row)
      exists? = Enum.any?(panes, &(&1.session == session))

      args =
        if exists?,
          do: ["new-window", "-d", "-t", "=" <> session <> ":", "-n", row.name],
          else: ["new-session", "-d", "-s", session, "-n", row.name]

      with {:ok, pane} <-
             tmux(socket, args ++ ["-P", "-F", "\#{pane_id}", "-c", row.workdir, command], opts),
           pane = String.trim(pane) do
        tmux(socket, ["set-option", "-w", "-t", pane, "automatic-rename", "off"], opts)
        checked(pane)
      end
    end
  end

  defp split(parent, dir, command),
    do: ["split-window", "-d", "-h", "-t", parent, "-P", "-F", "\#{pane_id}", "-c", dir, command]

  defp checked(pane) do
    if Regex.match?(~r/\A%\d+\z/, pane), do: {:ok, pane}, else: {:error, :tmux_unavailable}
  end

  defp parent_pane(%{parent_id: nil}, _), do: nil

  defp parent_pane(row, panes) do
    case AgentSessions.get(row.parent_id) do
      %AgentSession{ended_at: nil, pane_id: "%" <> _ = pane} = parent ->
        if SessionPane.socket(parent.tmux_server) == SessionPane.socket(row.tmux_server),
          do: Enum.find(panes, &(&1.pane == pane))

      _ ->
        nil
    end
  end

  defp project_session(row) do
    Foreman.SessionTmux.configured_tmux_session() || row.project || "coordinator"
  end

  # The same shape as `pi-window`'s launch line, under the user's login shell.
  defp command(row, argv) do
    parent = row.parent_id && AgentSessions.get(row.parent_id)

    env =
      [
        {"FOREMAN_ACTOR", row.harness},
        {"FOREMAN_SESSION", row.name},
        {"FOREMAN_PARENT", (parent && parent.name) || ""},
        {"FOREMAN_TICKETS", row.ticket || ""}
      ]
      |> Enum.map_join(" ", fn {key, value} -> key <> "=" <> quote_arg(value) end)

    shims =
      if row.harness == "pi",
        do:
          "if [ -d \"$HOME/.pi/agent/shims\" ]; then PATH=\"$HOME/.pi/agent/shims:$PATH\"; fi; ",
        else: ""

    scrub =
      "for name in $(env | cut -d= -f1); do " <>
        "case \"$name\" in RELEASE_*|PHX_*|FOREMAN_DATABASE_URL|DATABASE_URL|SECRET_KEY_BASE) unset \"$name\";; esac; done; "

    line =
      scrub <>
        "export " <>
        env <>
        "; " <>
        shims <>
        board_state(row, "running") <>
        Enum.map_join(argv, " ", &quote_arg/1) <>
        "; " <>
        board_state(row, "ended") <>
        "echo; echo #{quote_arg("[#{row.harness} exited] press enter")}; read line"

    "exec \"$SHELL\" -ilc " <> quote_arg(line)
  end

  defp board_state(%{tmux_server: "board"}, state),
    do:
      "tmux -N -L " <>
        quote_arg(SessionPane.socket("board")) <>
        " set-option -w -t \"$TMUX_PANE\" @foreman-state " <> state <> "; "

  defp board_state(_, _), do: ""

  def window(row, opts) do
    with {:ok, window} <-
           tmux(
             SessionPane.socket(row.tmux_server),
             ["display-message", "-p", "-t", row.pane_id, "\#{window_id}"],
             opts
           ),
         window = String.trim(window),
         true <- Regex.match?(~r/\A@\d+\z/, window) do
      {:ok, window}
    else
      _ -> {:error, :tmux_unavailable}
    end
  end

  @doc "Pins Bifrost before the first resumed message; a failed check sends no message."
  def activate_model(%{harness: "pi"} = row, opts) do
    socket = SessionPane.socket(row.tmux_server)

    with :ok <- Foreman.Preview.allow_external_write(),
         :ok <- wait_screen(row, socket, opts, false, 60),
         :ok <- send_line(socket, row.pane_id, "/bifrost pin", opts),
         :ok <- wait_screen(row, socket, opts, true, 15),
         do: send_line(socket, row.pane_id, "continue", opts)
  end

  def activate_model(%{harness: "claude"}, _opts), do: :ok

  defp wait_screen(_, _, _, _, 0), do: {:error, :pin_unconfirmed}

  defp wait_screen(row, socket, opts, pinned?, attempts) do
    with {:ok, text} <- tmux(socket, ["capture-pane", "-p", "-J", "-t", row.pane_id], opts),
         {:ok, command} <-
           tmux(
             socket,
             ["display-message", "-p", "-t", row.pane_id, "\#{pane_current_command}"],
             opts
           ) do
      marker = if pinned?, do: "Bifrost · pinned", else: "Bifrost"

      footer =
        text |> String.trim_trailing() |> String.split("\n") |> Enum.take(-8) |> Enum.join("\n")

      if String.trim(command) in ["pi", "node"] and String.contains?(footer, marker) and
           String.contains?(footer, List.last(String.split(row.model, "/"))) do
        :ok
      else
        Process.sleep(Keyword.get(opts, :poll_delay, 1000))
        wait_screen(row, socket, opts, pinned?, attempts - 1)
      end
    end
  end

  defp send_line(socket, pane, text, opts) do
    with {:ok, _} <- tmux(socket, ["send-keys", "-t", pane, "-l", "--", text], opts) do
      Process.sleep(Keyword.get(opts, :key_delay, 500))
      with {:ok, _} <- tmux(socket, ["send-keys", "-t", pane, "Enter"], opts), do: :ok
    end
  end

  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp tmux(socket, args, opts) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    # tmux otherwise takes PATH and the service settings from this client.
    env = for {key, _} <- System.get_env(), key != "TMUX_TMPDIR", do: {key, nil}

    case runner.("tmux", ["-N", "-L", socket | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      _ -> {:error, :tmux_unavailable}
    end
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end
end
