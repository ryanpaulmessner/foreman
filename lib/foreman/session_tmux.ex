defmodule Foreman.SessionTmux do
  @moduledoc "Dedicated-server adapter. Parking closes only an identified, unattached window; other operations preserve windows."

  def respawn_coordinator(session, mode, pane, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, command} <- coordinator_wrapper(session, mode, opts),
         {:ok, _} <-
           cmd(["set-option", "-w", "-t", session.window, "@foreman-state", "starting"], opts),
         {:ok, _} <-
           cmd(["set-option", "-w", "-t", session.window, "automatic-rename", "off"], opts),
         {:ok, _} <- cmd(["respawn-pane", "-k", "-t", pane, "-c", session.workdir, command], opts),
         {:ok, _} <-
           cmd(
             ["set-option", "-w", "-t", session.window, "@foreman-session", session.session_id],
             opts
           ) do
      :ok
    else
      {:error, {:tmux, _}} -> {:error, :tmux_unavailable}
      error -> error
    end
  end

  def coordinator_pane(request, opts \\ [])

  def coordinator_pane(%{"socket" => expected, "pane" => pane}, opts) do
    with true <- is_binary(pane) and Regex.match?(~r/\A%\d+\z/, pane),
         {:ok, output} <-
           cmd(
             [
               "display-message",
               "-p",
               "-t",
               pane,
               ~S(#{socket_path}|#{session_name}|#{window_name}|#{window_id})
             ],
             opts
           ),
         [^expected, "coordinator", _name, window] <- String.split(String.trim(output), "|") do
      {:ok, window}
    else
      _ -> {:error, :invalid_coordinator_pane}
    end
  end

  def coordinator_pane(_, _), do: {:error, :invalid_coordinator_pane}

  def coordinator_wrapper(session, mode, opts \\ []) do
    with :ok <- validate(session),
         executable when is_binary(executable) <-
           System.find_executable(Keyword.get(opts, :executable, "claude")) do
      {:ok,
       wrapper(
         session,
         "/orient",
         opts |> Keyword.put(:executable, executable) |> Keyword.put(:resume, mode == :resume)
       )}
    else
      nil -> {:error, :claude_unavailable}
      error -> error
    end
  end

  def focus(session, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, %{window: window}} <- observe(session, opts),
         {:ok, _} <- cmd(["select-window", "-t", window], opts),
         do: switch_latest_client(window, opts)
  end

  # Selecting a window only changes what an attached client sees if that client
  # is on the window's session; move the most recently active client there too.
  defp switch_latest_client(window, opts) do
    with {:ok, out} <- cmd(["list-clients", "-F", ~S(#{client_activity} #{client_name})], opts) do
      latest =
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          with [activity, client] <- String.split(line, " ", parts: 2),
               {activity, ""} <- Integer.parse(activity),
               do: [{activity, client}],
               else: (_ -> [])
        end)
        |> Enum.max_by(&elem(&1, 0), fn -> nil end)

      case latest do
        nil ->
          :ok

        {_, client} ->
          with {:ok, _} <- cmd(["switch-client", "-c", client, "-t", window], opts), do: :ok
      end
    end
  end

  def external_target(window, opts \\ []) do
    format =
      Enum.join(
        [
          ~S(#{session_name}),
          ~S(#{window_name}),
          ~S(#{window_id}),
          ~S(#{pane_id}),
          ~S(#{pane_pid}),
          ~S(#{pane_active})
        ],
        "\t"
      )

    with true <- is_binary(window) and window != "",
         {:ok, output} <- external_cmd(["list-panes", "-a", "-F", format], opts),
         [[project, _name, wid, pane, pid, "1"]] <-
           output
           |> String.split("\n", trim: true)
           |> Enum.map(&String.split(&1, "\t"))
           |> Enum.filter(fn
             [_, name, wid, _, _, "1"] -> window in [name, wid]
             _ -> false
           end),
         {:ok, content} <- external_cmd(["capture-pane", "-p", "-J", "-t", pane], opts) do
      {:ok,
       %{
         "target" => "external",
         "window" => wid,
         "pane" => pane,
         "pid" => pid,
         "snapshot" => digest(content),
         "attach" =>
           "tmux -L " <>
             quote_arg(external_socket(opts)) <> " attach -t " <> quote_arg(project <> ":" <> wid)
       }}
    else
      _ -> {:error, :invalid_window}
    end
  end

  def continue_external(facts, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, current} <- external_target(facts["window"], opts),
         true <-
           Map.take(current, ~w(pane pid snapshot)) == Map.take(facts, ~w(pane pid snapshot)),
         {:ok, _} <-
           external_cmd(
             [
               "send-keys",
               "-t",
               facts["pane"],
               "-l",
               "continue",
               ";",
               "send-keys",
               "-t",
               facts["pane"],
               "Enter"
             ],
             opts
           ) do
      :ok
    else
      _ -> {:error, :invalid_window}
    end
  end

  defp digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16()

  defp external_socket(opts),
    do:
      Keyword.get(opts, :socket, Application.get_env(:foreman, :external_tmux_socket, "default"))

  defp external_cmd(args, opts) do
    prefix = ["-N", "-L", external_socket(opts)]

    case System.cmd("tmux", prefix ++ args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      _ -> {:error, :tmux_unavailable}
    end
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end

  def continue_session(session, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, %{window: window, state: :running}} when window == session.window <-
           observe(session, opts),
         {:ok, identity} <-
           cmd(
             ["display-message", "-p", "-t", session.window, ~S(#{@foreman-session} #{pane_id})],
             opts
           ),
         [id, pane] when id == session.session_id <- String.split(String.trim(identity), " "),
         {:ok, _} <-
           cmd(
             ["send-keys", "-t", pane, "-l", "continue", ";", "send-keys", "-t", pane, "Enter"],
             opts
           ) do
      :ok
    else
      _ -> {:error, :invalid_window}
    end
  end

  def launch(session, prompt, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         :ok <- validate(session),
         {:ok, windows} <- windows(opts) do
      case Enum.find(windows, &matches?(&1, session)) do
        nil ->
          create(session, prompt, windows, opts)

        window ->
          with {:ok, _} <- cmd(["select-window", "-t", window.window], opts),
               do: {:ok, window.window}
      end
    end
  end

  def resume(session, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         :ok <- validate(session),
         {:ok, windows} <- windows(opts) do
      create(session, nil, windows, Keyword.put(opts, :resume, true))
    end
  end

  def observe(session, opts \\ []) do
    with {:ok, windows} <- windows(opts) do
      case Enum.find(windows, &matches?(&1, session)) do
        nil -> {:ok, :window_gone}
        w -> {:ok, %{window: w.window, state: w.state}}
      end
    end
  end

  # The guard and kill run in one tmux command queue, not a shell check/kill race.
  # An unknown identity or attached client fails closed.
  def park(session, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         true <- is_binary(session.window) and Regex.match?(~r/\A@\d+\z/, session.window),
         {:ok, output} <-
           cmd(
             [
               "if-shell",
               "-F",
               "-t",
               session.window,
               "\#{&&:\#{==:\#{@foreman-session},#{session.session_id}},\#{==:\#{window_active_clients},0}}",
               "kill-window -t #{session.window}",
               "display-message -p parking-refused"
             ],
             opts
           ) do
      if String.trim(output) == "", do: :ok, else: {:error, :parking_refused}
    else
      _ -> {:error, :parking_refused}
    end
  end

  def attached?(session, opts \\ []) do
    with {:ok, output} <-
           cmd(
             ["display-message", "-p", "-t", session.window, ~S(#{window_active_clients})],
             opts
           ),
         {count, ""} <- Integer.parse(String.trim(output)) do
      {:ok, count > 0}
    else
      _ -> {:error, :tmux_unavailable}
    end
  end

  def attach_command(session, opts \\ []) do
    "tmux -L #{quote_arg(socket(opts))} attach -t #{quote_arg(tmux_project(session) <> ":" <> (Map.get(session, :window) || session.ticket))}"
  end

  defp create(s, prompt, windows, opts) do
    case System.find_executable(Keyword.get(opts, :executable, "claude")) do
      nil -> {:error, :claude_unavailable}
      executable -> open_window(s, prompt, windows, Keyword.put(opts, :executable, executable))
    end
  end

  defp open_window(s, prompt, windows, opts) do
    command = wrapper(s, prompt, opts)

    args =
      if Enum.any?(windows, &(&1.project == tmux_project(s))),
        do: ["new-window", "-t", "=" <> tmux_project(s) <> ":", "-n", s.ticket],
        else: ["new-session", "-E", "-d", "-s", tmux_project(s), "-n", s.ticket]

    with {:ok, output} <-
           cmd(args ++ ["-P", "-F", ~S(#{window_id}), "-c", s.workdir, command], opts) do
      window = String.trim(output)

      if Regex.match?(~r/\A@\d+\z/, window) do
        with {:ok, _} <-
               cmd(["set-option", "-w", "-t", window, "@foreman-session", s.session_id], opts),
             do: {:ok, window}
      else
        {:error, :tmux_unavailable}
      end
    end
  end

  defp wrapper(s, prompt, opts) do
    tmux = "tmux -L " <> quote_arg(socket(opts))
    claude = Keyword.get(opts, :executable, "claude")

    args =
      if Keyword.get(opts, :resume, false),
        do: [
          claude,
          "--resume",
          s.session_id,
          "--settings",
          Jason.encode!(Foreman.SessionHooks.settings(s, opts))
        ],
        else: [
          claude,
          "--session-id",
          s.session_id,
          "--settings",
          Jason.encode!(Foreman.SessionHooks.settings(s, opts)),
          prompt
        ]

    args =
      if Foreman.Sessions.coordinator?(s) and Keyword.get(opts, :resume, false),
        do: args ++ ["/orient"],
        else: args

    # Match a normal tmux window's interactive login startup, then remove service
    # settings even if a local shell startup file reintroduces them.
    scrub =
      "for name in $(env | cut -d= -f1); do " <>
        "case \"$name\" in RELEASE_*|PHX_*|FOREMAN_DATABASE_URL|SECRET_KEY_BASE) unset \"$name\";; esac; done; "

    # All variable text becomes a single shell argument, including multiline prompts.
    command =
      scrub <>
        "#{tmux} set-option -w -t \"$TMUX_PANE\" @foreman-session #{quote_arg(s.session_id)}; " <>
        "#{tmux} set-option -w -t \"$TMUX_PANE\" automatic-rename off; " <>
        "#{tmux} set-option -w -t \"$TMUX_PANE\" @foreman-state running; " <>
        Enum.map_join(
          args,
          " ",
          &quote_arg/1
        ) <>
        "; #{tmux} set-option -w -t \"$TMUX_PANE\" @foreman-state ended; exec \"$SHELL\" -l"

    "exec \"$SHELL\" -ilc " <> quote_arg(command)
  end

  defp windows(opts) do
    format =
      ~S(#{session_name}\t#{window_name}\t#{window_id}\t#{@foreman-state}\t#{pane_dead}\t#{@foreman-session})

    format = String.replace(format, "\\t", "\t")

    case cmd(["list-windows", "-a", "-F", format], opts) do
      {:ok, output} ->
        rows =
          for line <- String.split(output, "\n", trim: true),
              [project, ticket, window, state, dead, identity] = String.split(line, "\t"),
              do: %{
                project: project,
                ticket: ticket,
                identity: identity,
                window: window,
                state:
                  cond do
                    dead == "1" or state == "ended" -> :ended
                    state == "running" -> :running
                    true -> :starting
                  end
              }

        {:ok, rows}

      {:error, {:tmux, output}} ->
        if String.contains?(output, [
             "no server running",
             "No such file or directory",
             "no current target"
           ]),
           do: {:ok, []},
           else: {:error, :tmux_unavailable}

      error ->
        error
    end
  end

  defp matches?(window, session) do
    target = Map.get(session, :window)

    window.project == tmux_project(session) and
      if(target, do: window.window == target, else: window.ticket == session.ticket) and
      window.identity == session.session_id
  end

  defp tmux_project(s),
    do: if(Foreman.Sessions.coordinator?(s), do: "coordinator", else: s.project)

  defp validate(s) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, s.project) and
         Regex.match?(~r/\A[a-zA-Z0-9_.:-]+\z/, s.ticket) and File.dir?(s.workdir),
       do: :ok,
       else: {:error, :invalid_launch_target}
  end

  defp socket(opts),
    do:
      Keyword.get(opts, :socket, Application.get_env(:foreman, :planning_tmux_socket, "foreman"))

  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp cmd(args, opts) do
    case System.cmd("tmux", ["-u", "-N", "-L", socket(opts), "-f", "/dev/null"] ++ args,
           stderr_to_stdout: true,
           # tmux otherwise takes PATH from this client, overriding the clean
           # server/session environment. Never send the web service environment.
           env: Enum.map(System.get_env(), fn {key, _} -> {key, nil} end)
         ) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, {:tmux, out}}
    end
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end
end
