defmodule Foreman.RequestSource do
  @moduledoc "The card's source session: its `agent_sessions` row, and focus on its pane."

  @doc """
  The card's source, from its `agent_session_id` (fixed when the ask was accepted). A card
  asked before identity rows existed uses the row with its session name that was live when
  it was asked (D3). Never reads tmux and never guesses from a live window name.
  """
  def for_request(request, _opts \\ []) do
    if row = row(request), do: source(row)
  end

  @roles %{"main_coordinator" => "main coordinator", "epic_coordinator" => "epic coordinator"}

  @doc """
  The card's source row view (question cards spec, Decision 14), the one place a
  card reads who asked it: `state` (`:live`, `:ended` or `:unknown`), the session
  `name`, its `role` in the Sessions words, `ended_at`, and `focus` (the Focus
  terminal icon is on), and `link` to the session page. `receiver` (where an
  answer goes, fm-9mm.15) and `resumes` stay empty until that work ships.
  """
  def view(request) do
    case row(request) do
      nil ->
        %{
          state: :unknown,
          name: nil,
          role: nil,
          ended_at: nil,
          focus: false,
          link: nil,
          receiver: nil,
          resumes: false,
          source: nil
        }

      row ->
        %{
          state: if(row.ended_at, do: :ended, else: :live),
          name: row.name,
          role: role(row),
          ended_at: row.ended_at,
          focus: is_nil(row.ended_at),
          link: "/sessions/#{row.id}",
          receiver: nil,
          resumes: false,
          source: source(row)
        }
    end
  end

  defp row(request) do
    case Map.get(request, :agent_session_id) do
      nil -> Foreman.AgentSessions.legacy(request)
      id -> Foreman.AgentSessions.get(id)
    end
  end

  defp role(%{kind: "build", parent_id: parent}) when is_binary(parent) do
    case Foreman.AgentSessions.get(parent) do
      %{name: name} -> "build under " <> name
      nil -> "build"
    end
  end

  defp role(%{kind: kind, harness: harness}), do: @roles[kind] || kind || harness

  @doc "The source shape cards use for an `agent_sessions` row."
  def source(%Foreman.AgentSession{} = row) do
    target = Foreman.AgentSessions.target(row)

    %{
      name: row.name,
      harness: row.harness,
      target: target.target,
      server: target.server,
      agent_session_id: row.id,
      kind: row.kind
    }
    |> ended(row)
  end

  defp ended(source, %{ended_at: at}) when not is_nil(at), do: Map.put(source, :ended_at, at)
  defp ended(source, _), do: source

  def focus(source, opts \\ [])
  def focus(%{ended_at: at}, _opts) when not is_nil(at), do: {:error, :window_gone}

  def focus(source, opts) do
    run = fn args ->
      runner = Keyword.get(opts, :runner, &System.cmd/3)

      case runner.("tmux", server_args(source) ++ args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        _ -> {:error, :tmux_unavailable}
      end
    end

    with :ok <- allow_focus(),
         {:ok, panes} <-
           run.([
             "list-panes",
             "-a",
             "-F",
             "\#{pane_id}\t\#{window_id}\t\#{session_name}\t\#{window_name}\t\#{pane_active}"
           ]),
         {:ok, pane, _window} <- target(panes, source.target),
         do: Foreman.SessionFocus.show(pane, run, opts)
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end

  def pane(source, opts \\ [])
  def pane(%{ended_at: at}, _opts) when not is_nil(at), do: {:error, :window_gone}

  def pane(source, opts) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    args = [
      "list-panes",
      "-a",
      "-F",
      "\#{pane_id}\t\#{window_id}\t\#{session_name}\t\#{window_name}\t\#{pane_active}"
    ]

    case runner.("tmux", server_args(source) ++ args, stderr_to_stdout: true) do
      {output, 0} ->
        case target(output, source.target) do
          {:ok, pane, _window} -> {:ok, pane}
          error -> error
        end

      _ ->
        {:error, :tmux_unavailable}
    end
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end

  def command(source) do
    tmux = "tmux"
    target = quote_arg(source.target)

    pane =
      if String.starts_with?(source.target, "%"),
        do: "#{tmux} select-pane -t #{target} && ",
        else: ""

    session = "$(#{tmux} display-message -p -t #{target} '\#{session_id}')"

    "#{tmux} select-window -t #{target} && #{pane}if [ -n \"$TMUX\" ]; then #{tmux} switch-client -t \"#{session}\"; else #{tmux} attach-session -t \"#{session}\"; fi"
  end

  defp allow_focus do
    case Foreman.Preview.allow_external_write() do
      :ok -> :ok
      {:error, _} -> {:error, :tmux_unavailable}
    end
  end

  defp server_args(source), do: ["-N", "-L", socket(source)]

  defp socket(%{server: :board}),
    do: Application.get_env(:foreman, :planning_tmux_socket, "foreman")

  defp socket(_), do: Application.get_env(:foreman, :external_tmux_socket, "default")
  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp target(output, target) do
    matches =
      for line <- String.split(output, "\n", trim: true),
          [pane, window, session, name, active] <- [String.split(line, "\t")],
          target == pane or (active == "1" and target in [window, name, session <> ":" <> name]),
          do: {pane, window}

    case Enum.uniq_by(matches, &elem(&1, 1)) do
      [{pane, window}] -> {:ok, pane, window}
      _ -> {:error, :window_gone}
    end
  end
end
