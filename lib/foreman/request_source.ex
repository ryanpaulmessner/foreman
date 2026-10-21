defmodule Foreman.RequestSource do
  @moduledoc "Resolves a request to its registered session without guessing a tmux target."
  import Ecto.Query

  def for_request(request) do
    dispatches =
      Foreman.Repo.all(
        from s in "sessions",
          where:
            s.repo_key == ^request.repo_key and s.bead_id == ^request.bead_id and
              s.started_at <= ^request.inserted_at,
          order_by: [desc: s.id],
          select: %{window: s.window, details: s.details}
      )

    resolve(request, dispatches, Foreman.Sessions.get({request.repo_key, request.bead_id}))
  end

  def resolve(request, dispatches, planning \\ nil) do
    cond do
      is_nil(request.session) ->
        nil

      planning && planning.session_id == request.session && planning.window ->
        %{name: planning.ticket, harness: "claude", target: planning.window, server: :board}

      dispatch =
          Enum.find(dispatches, &matches?(&1, request.session)) ||
            legacy_pane(List.first(dispatches), request.actor) ->
        %{
          name: request.session,
          harness: dispatch.details["harness"] || request.actor,
          target: dispatch.window,
          server: :default
        }

      pane = external_waiting_pane(request) ->
        %{name: request.session, harness: request.actor, target: pane, server: :default}

      true ->
        nil
    end
  end

  defp legacy_pane(%{window: "%" <> _, details: details} = dispatch, actor) do
    if is_nil(details["session"]) and details["harness"] == actor, do: dispatch
  end

  defp legacy_pane(_, _), do: nil

  defp external_waiting_pane(%{
         kind: "session_waiting",
         facts: %{"target" => "external", "pane" => "%" <> _ = pane}
       }),
       do: pane

  defp external_waiting_pane(_), do: nil

  def focus(source, opts \\ []) do
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
         {:ok, pane, window} <- target(panes, source.target),
         {:ok, clients} <- run.(["list-clients", "-F", "\#{client_activity}\t\#{client_name}"]),
         {:ok, client} <- client(clients),
         {:ok, _} <- run.(["switch-client", "-c", client, "-t", pane]),
         {:ok, _} <- run.(["select-window", "-t", window]),
         {:ok, _} <- run.(["select-pane", "-t", pane]),
         do: :ok
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end

  def pane(source, opts \\ []) do
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
    tmux = "tmux -L " <> quote_arg(socket(source))
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

  defp client(output) do
    clients =
      for line <- String.split(output, "\n", trim: true),
          [activity, client] <- [String.split(line, "\t")],
          {time, ""} <- [Integer.parse(activity)],
          do: {time, client}

    case Enum.sort(clients, :desc) do
      [{_, client} | _] -> {:ok, client}
      [] -> {:error, :no_client}
    end
  end

  defp matches?(dispatch, name),
    do:
      is_binary(dispatch.window) and
        (dispatch.details["session"] == name or dispatch.window == name)
end
