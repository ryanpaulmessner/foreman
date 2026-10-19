defmodule Foreman.Terminal do
  @moduledoc """
  Brings the user's terminal app to the front after a session is shown in tmux.
  macOS only (osascript); elsewhere a no-op. The app is `board.terminal_app` in
  foreman.toml, Ghostty by default. Failure never blocks the tmux switch.
  """

  @default "Ghostty"

  def activate(opts \\ []) do
    app = Keyword.get_lazy(opts, :app, &configured_app/0)
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    if Keyword.get(opts, :platform, :os.type()) == {:unix, :darwin} and app?(app) do
      try do
        runner.("osascript", ["-e", ~s(tell application "#{app}" to activate)],
          stderr_to_stdout: true
        )
      rescue
        ErlangError -> :ok
      end
    end

    :ok
  end

  def app?(app), do: is_binary(app) and Regex.match?(~r/\A[\p{L}\p{N} ._-]{1,64}\z/u, app)

  defp configured_app do
    case Foreman.RuntimeState.config() do
      %{config: %{"board" => %{"terminal_app" => app}}} -> app
      _ -> @default
    end
  end
end
