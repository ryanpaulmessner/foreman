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

  @doc """
  Shows a board-launched session's pane in the most recently active attached client:
  switch-client to a pane target changes session, window and pane together.
  """
  def open_session(session, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, pane} <- session_pane(session, opts),
         do: show(pane, &cmd(&1, opts))
  end

  def open_external(facts, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, current} <- external_pane(facts, opts),
         do: show(current["pane"], &external_cmd(&1, opts))
  end

  @doc "Answers a question prompt that is still on screen; otherwise `{:error, :prompt_changed}`."
  def answer_session(session, question, choice, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, pane} <- session_pane(session, opts),
         do: answer(pane, question, choice, &cmd(&1, opts), opts)
  end

  def answer_external(facts, question, choice, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, current} <- external_pane(facts, opts) do
      if Map.take(current, ~w(pane pid)) == Map.take(facts, ~w(pane pid)),
        do: answer(facts["pane"], question, choice, &external_cmd(&1, opts), opts),
        else: {:error, :prompt_changed}
    end
  end

  @doc "Types a reply into a session's empty, idle chat prompt; otherwise `{:error, :prompt_busy}`."
  def reply_session(session, text, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, pane} <- session_pane(session, opts),
         do: type_reply(pane, text, &cmd(&1, opts), opts)
  end

  def reply_external(facts, text, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, current} <- external_pane(facts, opts) do
      if Map.take(current, ~w(pane pid)) == Map.take(facts, ~w(pane pid)) do
        check = if opts[:harness] == "pi", do: &pi_prompt/2, else: &prompt_idle/2
        type_reply(facts["pane"], text, &external_cmd(&1, opts), opts, check)
      else
        {:error, :window_gone}
      end
    end
  end

  def reply_source(source, text, opts \\ []) do
    run = if source.server == :board, do: &cmd(&1, opts), else: &external_cmd(&1, opts)

    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, pane} <- Foreman.RequestSource.pane(source, opts) do
      case source.harness do
        "claude" -> type_reply(pane, text, run, opts)
        "pi" -> type_reply(pane, text, run, opts, &pi_prompt/2)
        _ -> {:error, :prompt_busy}
      end
    end
  end

  defp pi_prompt(pane, run) do
    with {:ok, identity} <-
           tmux(run, [
             "display-message",
             "-p",
             "-t",
             pane,
             "\#{pane_current_command}\t\#{pane_start_command}"
           ]),
         [command, start] <- String.split(String.trim(identity), "\t", parts: 2),
         true <- command in ["node", "pi"] and Regex.match?(~r/(?:^|\s)pi(?:\s|$)/, start),
         {:ok, screen} <- tmux(run, ["capture-pane", "-p", "-J", "-t", pane]),
         true <- empty_pi_editor?(screen) do
      :ok
    else
      _ -> {:error, :prompt_busy}
    end
  end

  defp empty_pi_editor?(screen) do
    lines = screen |> String.trim_trailing() |> String.split("\n") |> Enum.reverse()
    not_rule? = &(not Regex.match?(~r/\A─{3,}/u, &1))

    with {footer, [_bottom | rest]} <- Enum.split_while(lines, not_rule?),
         true <- length(footer) <= 4,
         {input, [_top | _]} <- Enum.split_while(rest, not_rule?) do
      input != [] and Enum.all?(input, &(String.trim(&1) == ""))
    else
      _ -> false
    end
  end

  defp type_reply(pane, text, run, opts, check \\ &prompt_idle/2) do
    with {:ok, [{:literal, text}, :enter]} <- Foreman.ChatPrompt.keys(text),
         :ok <- check.(pane, run),
         {:ok, _} <- tmux(run, ["send-keys", "-t", pane, "-l", "--", text]) do
      # Claude reads typed text and Enter on separate renders; never coalesce them.
      Process.sleep(Keyword.get(opts, :key_delay, 150))
      with {:ok, _} <- tmux(run, ["send-keys", "-t", pane, "Enter"]), do: :ok
    end
  end

  defp external_pane(facts, opts) do
    case external_target(facts["window"], opts) do
      {:ok, current} -> {:ok, current}
      _ -> {:error, :window_gone}
    end
  end

  defp session_pane(session, opts) do
    with {:ok, %{window: window}} when window == session.window <- observe(session, opts),
         {:ok, identity} <-
           cmd(["display-message", "-p", "-t", window, ~S(#{@foreman-session} #{pane_id})], opts),
         [id, pane] when id == session.session_id <- String.split(String.trim(identity), " ") do
      {:ok, pane}
    else
      {:error, :tmux_unavailable} -> {:error, :tmux_unavailable}
      _ -> {:error, :window_gone}
    end
  end

  defp show(pane, run) do
    with {:ok, output} <-
           tmux(run, ["list-clients", "-F", "\#{client_activity}\t\#{client_name}"]) do
      clients =
        for line <- String.split(output, "\n", trim: true),
            [activity, name] <- [String.split(line, "\t", parts: 2)],
            {activity, ""} <- [Integer.parse(activity)],
            do: {activity, name}

      case clients do
        [] ->
          {:error, :no_client}

        clients ->
          {_, client} = Enum.max(clients)

          with {:ok, _} <- tmux(run, ["switch-client", "-c", client, "-t", pane]), do: :ok
      end
    end
  end

  defp answer(pane, question, choice, run, opts) do
    with {:ok, keys} <- Foreman.QuestionPrompt.keys(question, choice),
         :ok <- prompt_shown(pane, question, run) do
      keys
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {key, index}, :ok ->
        # Claude reads each keystroke batch on its own render; never coalesce them.
        if index > 0, do: Process.sleep(Keyword.get(opts, :key_delay, 150))

        case send_key(pane, key, question, run, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp prompt_idle(pane, run) do
    with {:ok, screen} <- tmux(run, ["capture-pane", "-p", "-J", "-t", pane]) do
      if Foreman.ChatPrompt.idle?(screen), do: :ok, else: {:error, :prompt_busy}
    end
  end

  defp prompt_shown(pane, question, run) do
    with {:ok, screen} <- tmux(run, ["capture-pane", "-p", "-J", "-t", pane]) do
      if Foreman.QuestionPrompt.shown?(screen, question),
        do: :ok,
        else: {:error, :prompt_changed}
    end
  end

  defp send_key(pane, {:literal, text}, _, run, _),
    do: with({:ok, _} <- tmux(run, ["send-keys", "-t", pane, "-l", "--", text]), do: :ok)

  defp send_key(pane, :enter, _, run, _),
    do: with({:ok, _} <- tmux(run, ["send-keys", "-t", pane, "Enter"]), do: :ok)

  # The free-text row must hold the pointer before any text is typed, or the
  # text's digits would pick options.
  defp send_key(pane, :focus, question, run, opts) do
    # Bounded: the caller holds the project lock that hooks also take.
    Enum.reduce_while(1..6, {:error, :prompt_changed}, fn attempt, _ ->
      if attempt > 1, do: Process.sleep(Keyword.get(opts, :key_delay, 150))

      case tmux(run, ["capture-pane", "-p", "-J", "-t", pane]) do
        {:ok, screen} ->
          if Foreman.QuestionPrompt.other_focused?(screen, question),
            do: {:halt, :ok},
            else: {:cont, {:error, :prompt_changed}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp tmux(run, args) do
    case run.(args) do
      {:ok, output} -> {:ok, output}
      _ -> {:error, :tmux_unavailable}
    end
  end

  defp digest(content), do: :crypto.hash(:sha256, content) |> Base.encode16()

  defp external_socket(opts),
    do:
      Keyword.get(opts, :socket, Application.get_env(:foreman, :external_tmux_socket, "default"))

  defp external_cmd(args, opts) do
    prefix = ["-N", "-L", external_socket(opts)]

    case runner(opts).("tmux", prefix ++ args, stderr_to_stdout: true) do
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

  # `board.tmux_session` in foreman.toml puts every launched session in one tmux
  # session (one window each); without it, coordinators go to "coordinator" and
  # other launches to a tmux session named after their project.
  defp tmux_project(s) do
    case configured_tmux_session() do
      name when is_binary(name) -> name
      _ -> if(Foreman.Sessions.coordinator?(s), do: "coordinator", else: s.project)
    end
  end

  defp configured_tmux_session do
    Application.get_env(:foreman, :tmux_session) || board_tmux_session()
  end

  defp board_tmux_session do
    case Foreman.RuntimeState.config() do
      %{config: %{"board" => %{"tmux_session" => name}}} -> name
      _ -> nil
    end
  rescue
    _ -> nil
  end

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

  # Tests pass a stub with System.cmd/3's shape; production always runs tmux.
  defp runner(opts), do: Keyword.get(opts, :runner, &System.cmd/3)

  defp cmd(args, opts) do
    case runner(opts).("tmux", ["-u", "-N", "-L", socket(opts), "-f", "/dev/null"] ++ args,
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
