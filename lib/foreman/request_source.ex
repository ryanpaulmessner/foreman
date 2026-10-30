defmodule Foreman.RequestSource do
  @moduledoc "Resolves the card's own named session before a unique live tmux name or tag."
  import Ecto.Query

  def for_request(request, opts \\ [])
  def for_request(%{session: nil}, _opts), do: nil

  def for_request(request, opts) do
    dispatches =
      Foreman.Repo.all(
        from s in "sessions",
          where: fragment("?->>'session'", s.details) == ^request.session,
          order_by: [desc: s.repo_key == "__foreman__" and s.bead_id == "registered", desc: s.id],
          select: %{window: s.window, details: s.details, ended_at: s.ended_at}
      )

    resolve(request, dispatches, Foreman.Sessions.get({request.repo_key, request.bead_id})) ||
      live_source(request, opts)
  end

  def resolve(request, dispatches, planning \\ nil) do
    cond do
      is_nil(request.session) ->
        nil

      planning && planning.session_id == request.session && planning.window ->
        %{name: planning.ticket, harness: "claude", target: planning.window, server: :board}

      dispatch = Enum.find(dispatches, &matches?(&1, request.session)) ->
        %{
          name: request.session,
          harness: dispatch.details["harness"] || request.actor,
          target: dispatch.window,
          server: :default
        }
        |> ended(dispatch)

      true ->
        nil
    end
  end

  defp live_source(request, opts) do
    case Foreman.SessionTargets.lookup(request.session, opts) do
      {:ok, pane} ->
        %{name: request.session, harness: request.actor, target: pane, server: :default}

      _ ->
        nil
    end
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

  defp matches?(dispatch, name),
    do:
      is_binary(dispatch.window) and
        (dispatch.details["session"] == name or dispatch.window == name)
end
