defmodule Foreman.TicketReadyOrderTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    dir = Path.join(System.tmp_dir!(), "foreman-ready-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    # macOS temp paths are symlinks; the CLI matches config against git's resolved root.
    {root, 0} = System.cmd("git", ["-C", dir, "rev-parse", "--show-toplevel"])
    root = String.trim(root)

    config = Path.join(root, "config")
    File.mkdir_p!(config)
    previous = System.get_env("FOREMAN_CONFIG_DIR")
    System.put_env("FOREMAN_CONFIG_DIR", config)

    File.write!(
      Path.join(config, "foreman.toml"),
      "[[repos]]\nkey = \"sample\"\npath = #{Jason.encode!(root)}\nprefix = \"zz\"\n"
    )

    on_exit(fn ->
      if previous,
        do: System.put_env("FOREMAN_CONFIG_DIR", previous),
        else: System.delete_env("FOREMAN_CONFIG_DIR")

      File.rm_rf!(dir)
    end)

    {:ok, root: root}
  end

  defp call(root, args, expected \\ 0) do
    output =
      capture_io(fn -> assert Foreman.CLI.run(args ++ ["--json"], cwd: root) == expected end)

    Jason.decode!(output)
  end

  defp ticket(root, id, priority, created) do
    File.write!(Path.join([root, "tickets", id <> ".md"]), """
    ---
    id: #{id}
    title: "Ticket #{id}"
    type: task
    status: open
    priority: #{priority}
    parent: null
    blocked_by: []
    related: []
    supersedes: []
    discovered_from: null
    labels: []
    created: #{created}
    closed: null
    close_reason: null
    ---
    """)
  end

  test "ready sorts by priority, then oldest first, then id", %{root: root} do
    File.mkdir_p!(Path.join(root, "tickets"))
    ticket(root, "zz-aaa", 2, "2026-10-01")
    ticket(root, "zz-bbb", 0, "2026-10-19")
    ticket(root, "zz-ccc", 2, "2026-09-01")
    ticket(root, "zz-ddd", 4, "2026-01-01")
    ticket(root, "zz-eee", 0, "2026-10-19")
    ticket(root, "zz-fff", 1, "2026-10-20")

    assert Enum.map(call(root, ["ready"]), & &1["id"]) ==
             ~w(zz-bbb zz-eee zz-fff zz-ccc zz-aaa zz-ddd)

    # ls keeps id order.
    assert Enum.map(call(root, ["ls"]), & &1["id"]) ==
             ~w(zz-aaa zz-bbb zz-ccc zz-ddd zz-eee zz-fff)
  end

  test "update --priority writes the file and validates the range", %{root: root} do
    id = call(root, ["new", "Task"])["id"]
    assert call(root, ["update", id, "--priority", "0"])["priority"] == 0
    assert File.read!(Path.join([root, "tickets", id <> ".md"])) =~ "priority: 0"
    assert call(root, ["update", id, "--priority", "7"], 2)["error"] =~ "priority"
    assert call(root, ["update", id, "--priority", "high"], 2)["error"] =~ "invalid"
    assert call(root, ["show", id])["priority"] == 0
  end
end
