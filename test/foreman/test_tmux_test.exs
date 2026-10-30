defmodule Foreman.TestTmuxTest do
  use ExUnit.Case, async: true

  test "cleanup removes the socket even when the server has already stopped" do
    socket = Foreman.TestTmux.socket("fm-cleanup")

    {_, 0} =
      System.cmd("tmux", ["-L", socket, "-f", "/dev/null", "new-session", "-d", "sleep 60"])

    {path, 0} = System.cmd("tmux", ["-L", socket, "display-message", "-p", ~S(#{socket_path})])
    path = String.trim(path)
    assert File.exists?(path)
    System.cmd("tmux", ["-L", socket, "kill-server"])
    assert :ok = Foreman.TestTmux.cleanup(socket)
    refute File.exists?(path)
    assert :ok = Foreman.TestTmux.cleanup(socket)
  end
end
