defmodule Foreman.BoardLogTest do
  use ExUnit.Case, async: true

  test "a short log line is written before the board exits" do
    root = Path.join(System.tmp_dir!(), "board-log-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    log = Path.join(root, "board.log")

    script = """
    import pathlib, sys, time
    path = pathlib.Path(sys.argv[1])
    print('ready', flush=True)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if path.read_bytes() == b'ready\\n':
            sys.exit(0)
        time.sleep(0.01)
    sys.exit(1)
    """

    assert {"", 0} =
             System.cmd(
               "python3",
               ["deploy/launchd/board-log.py", log, "python3", "-c", script, log],
               stderr_to_stdout: true
             )
  end

  test "wrapper bounds log files, keeps stderr, and returns the command exit code" do
    root = Path.join(System.tmp_dir!(), "board-log-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    log = Path.join(root, "board.log")

    assert {"", 7} =
             System.cmd(
               "python3",
               [
                 "deploy/launchd/board-log.py",
                 "--size",
                 "100",
                 "--copies",
                 "5",
                 log,
                 "python3",
                 "-c",
                 "import sys; sys.stdout.write('a' * 650); sys.stdout.flush(); sys.stderr.write('END'); sys.exit(7)"
               ],
               stderr_to_stdout: true
             )

    assert length(Path.wildcard(log <> "*")) == 5
    for path <- Path.wildcard(log <> "*"), do: assert(File.stat!(path).size <= 100)
    assert File.read!(log) == String.duplicate("a", 50) <> "END"
    assert File.read!(log <> ".4") == String.duplicate("a", 100)
  end
end
