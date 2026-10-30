defmodule Foreman.SessionTargets do
  @moduledoc "Read-only lookup on the external tmux server; ambiguous names never select a pane."

  def lookup(name, opts \\ []) do
    with {:ok, panes} <- list(opts), do: find(panes, name)
  end

  def list(opts \\ []) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    socket =
      Keyword.get(opts, :socket, Application.get_env(:foreman, :external_tmux_socket, "default"))

    format =
      "\#{pane_id}\t\#{window_id}\t\#{session_name}\t\#{window_name}\t\#{pane_active}\t\#{@build}\t\#{@foreman-session}"

    case runner.("tmux", ["-N", "-L", socket, "list-panes", "-a", "-F", format],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        rows =
          for line <- String.split(output, "\n", trim: true),
              [pane, window, session, name, active, build, tag] <- [String.split(line, "\t")],
              do: %{
                pane: pane,
                window: window,
                session: session,
                name: name,
                active: active == "1",
                build: build,
                tag: tag
              }

        if length(rows) == length(String.split(output, "\n", trim: true)),
          do: {:ok, rows},
          else: {:error, :tmux_unavailable}

      {output, _} ->
        if String.starts_with?(output, "no server running on ") or
             (String.starts_with?(output, "error connecting to ") and
                String.contains?(output, "No such file or directory")),
           do: {:ok, []},
           else: {:error, :tmux_unavailable}
    end
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end

  def present?(panes, target),
    do: Enum.any?(panes, &(target in [&1.pane, &1.window, &1.name, &1.session <> ":" <> &1.name]))

  def find(panes, name) when is_binary(name) and name != "" do
    tagged = Enum.filter(panes, &(&1.build == name or (&1.tag == name and &1.build == "")))

    matches =
      if tagged == [],
        do:
          Enum.filter(
            panes,
            &(&1.pane == name or
                (&1.active and name in [&1.window, &1.name, &1.session <> ":" <> &1.name]))
          ),
        else: tagged

    case Enum.uniq_by(matches, & &1.pane) do
      [%{pane: pane}] ->
        {:ok, pane}

      [_ | _] = candidates ->
        if Enum.all?(candidates, &(&1.build == "")) and
             length(Enum.uniq_by(candidates, & &1.window)) == 1 do
          case Enum.filter(candidates, & &1.active) do
            [%{pane: pane}] -> {:ok, pane}
            _ -> {:error, :window_gone}
          end
        else
          {:error, :window_gone}
        end

      [] ->
        {:error, :window_gone}
    end
  end

  def find(_, _), do: {:error, :window_gone}
end
