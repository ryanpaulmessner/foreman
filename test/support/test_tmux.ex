defmodule Foreman.TestTmux do
  @moduledoc "Owns uniquely named test servers and their socket files."

  @doc "The default pane capture runner in tests: tmux does not answer."
  def no_capture(_command, _args, _opts), do: {"no tmux in tests", 1}

  def socket(prefix) do
    name = prefix <> "-" <> Ecto.UUID.generate()
    ExUnit.Callbacks.on_exit(fn -> cleanup(name) end)
    name
  end

  def cleanup(name) do
    System.cmd("tmux", ["-N", "-L", name, "kill-server"], stderr_to_stdout: true)
    {uid, 0} = System.cmd("id", ["-u"])
    root = System.get_env("TMUX_TMPDIR") || "/tmp"
    path = Path.join([root, "tmux-#{String.trim(uid)}", name])

    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "remove test socket", path: path
    end
  end
end
