defmodule Foreman.TicketCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    root = Path.join(System.tmp_dir!(), "foreman-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["init", "-q", root])

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

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  def call(root, args, expected \\ 0) do
    output =
      capture_io(fn -> assert Foreman.CLI.run(args ++ ["--json"], cwd: root) == expected end)

    Jason.decode!(output)
  end

  test "parking requires a reason, persists the date and clears both on start or reopen", %{
    root: root
  } do
    id = call(root, ["new", "Wait for IT"])["id"]
    path = Path.join([root, "tickets", id <> ".md"])
    before = File.read!(path)
    assert call(root, ["update", id, "--status", "parked"], 2)["error"] =~ "reason"
    assert File.read!(path) == before

    assert call(root, ["update", id, "--status", "parked", "--reason", "  "], 2)["error"] =~
             "reason"

    assert File.read!(path) == before

    for destination <- ["open", "in_progress", "deferred", "closed"] do
      parked = call(root, ["update", id, "--status", "parked", "--reason", "IT: VPN"])
      assert parked["status"] == "parked"
      assert {:ok, ticket} = Foreman.TicketFile.parse(File.read!(path))
      assert ticket.facts["parked_reason"] == "IT: VPN"
      assert ticket.facts["parked"] == Date.to_iso8601(Date.utc_today())
      call(root, ["update", id, "--status", destination])
      assert {:ok, ticket} = Foreman.TicketFile.parse(File.read!(path))
      assert ticket.facts["parked_reason"] == nil
      assert ticket.facts["parked"] == nil
    end
  end

  test "editing a parked reason retains its age; reopen clears parking", %{root: root} do
    id = call(root, ["new", "Waiting"])["id"]
    call(root, ["update", id, "--status", "parked", "--reason", "IT"])
    path = Path.join([root, "tickets", id <> ".md"])

    File.write!(
      path,
      String.replace(File.read!(path), "parked: #{Date.utc_today()}", "parked: 2020-01-01")
    )

    updated = call(root, ["update", id, "--status", "parked", "--reason", "Vendor"])
    assert updated["parked"] == "2020-01-01"
    assert updated["parked_reason"] == "Vendor"
    call(root, ["reopen", id])
    assert {:ok, ticket} = Foreman.TicketFile.parse(File.read!(path))
    assert ticket.facts["parked"] == nil
    assert ticket.facts["parked_reason"] == nil
  end

  test "new and update accept kind but invalid kinds never write", %{root: root} do
    ticket = call(root, ["new", "Kinds", "--kind", "feature"])
    id = ticket["id"]
    assert ticket["kind"] == "feature"
    assert call(root, ["update", id, "--kind", "access"])["kind"] == "access"
    path = Path.join([root, "tickets", id <> ".md"])
    before = File.read!(path)
    assert call(root, ["update", id, "--kind", "wrong"], 2)["error"] =~ "kind"
    assert File.read!(path) == before
    assert call(root, ["new", "Invalid", "--kind", "wrong"], 2)["error"] =~ "kind"
    assert length(Path.wildcard(Path.join(root, "tickets/*.md"))) == 1
  end

  test "an empty configured checkout lists tickets without a server", %{root: root} do
    assert call(root, ["ls"]) == []
    assert call(root, ["ready"]) == []
  end

  test "writer contention warns without failing agents while check fails closed", %{root: root} do
    File.mkdir_p!(Path.join([root, ".git", ".foreman-write-lock"]))
    assert call(root, ["new", "Task"])["warning"] =~ "write"
    assert call(root, ["check"], 2)["valid"] == false
  end

  test "options that do not belong to a command are rejected", %{root: root} do
    assert call(root, ["new", "Task", "--reason", "ignored"], 2)["error"] =~ "option"
    assert call(root, ["check", "--title", "ignored"], 2)["error"] =~ "option"
    refute File.exists?(Path.join(root, "tickets"))
  end

  test "all commands operate on files without transport or server", %{root: root} do
    epic = call(root, ["new", "The epic", "--type", "epic"])["id"]
    assert is_binary(epic) and Regex.match?(~r/^zz-[a-z0-9]{3}$/, epic)
    first = call(root, ["new", "First", "--parent", epic])["id"]
    second = call(root, ["new", "Second", "--parent", epic, "--blocked-by", first])["id"]
    assert first == epic <> ".1"
    assert second == epic <> ".2"
    assert Enum.map(call(root, ["ready"]), & &1["id"]) == [first]
    assert call(root, ["show", first])["title"] == "First"
    assert length(call(root, ["ls"])) == 3

    assert call(root, [
             "update",
             first,
             "--title",
             "Changed",
             "--priority",
             "0",
             "--labels",
             "z,a"
           ])["labels"] == ["a", "z"]

    assert call(root, ["close", first, "--reason", "Verified"])["status"] == "closed"
    assert Enum.map(call(root, ["ready"]), & &1["id"]) == [second]
    assert call(root, ["reopen", first])["closed"] == nil
    assert call(root, ["dep", "rm", second, first])["blocked_by"] == []
    assert call(root, ["dep", "add", second, first])["blocked_by"] == [first]

    assert call(root, ["note", second, "Evidence", "--actor", "builder"])["body"] =~
             "#{Date.utc_today()} builder: Evidence"

    assert [%{"id" => ^epic, "children" => [_, _]}] = call(root, ["tree"])
    assert call(root, ["check"]) == %{"errors" => [], "valid" => true}
    new_id = epic <> ".4"
    assert call(root, ["renumber", first, new_id])["id"] == new_id
    refute File.exists?(Path.join([root, "tickets", first <> ".md"]))
    assert call(root, ["show", second])["blocked_by"] == [new_id]
    assert call(root, ["check"])["valid"]
  end

  test "renumber rewrites all reference fields and Markdown links without changing longer ids", %{
    root: root
  } do
    old = call(root, ["new", "Original", "--type", "epic"])["id"]

    child =
      call(root, [
        "new",
        "Child",
        "--parent",
        old,
        "--related",
        old,
        "--supersedes",
        old,
        "--discovered-from",
        old,
        "--body",
        "See [ticket](#{old}.md), #{old}. Also #{old}.1 and x#{old}."
      ])["id"]

    call(root, ["renumber", old, "zz-new"])
    result = call(root, ["show", child])
    assert result["parent"] == "zz-new"
    assert result["related"] == ["zz-new"]
    assert result["supersedes"] == ["zz-new"]
    assert result["discovered_from"] == "zz-new"
    assert result["body"] == "See [ticket](zz-new.md), zz-new. Also #{old}.1 and x#{old}.\n"
  end

  test "chore supersedes absent tickets without becoming blocked", %{root: root} do
    ticket = call(root, ["new", "Cleanup", "--type", "chore", "--supersedes", "zz-old,zz-absent"])
    assert ticket["supersedes"] == ["zz-absent", "zz-old"]
    assert call(root, ["check"])["valid"]
    assert Enum.map(call(root, ["ready"]), & &1["id"]) == [ticket["id"]]
    assert call(root, ["update", ticket["id"], "--supersedes", ""])["supersedes"] == []

    assert call(root, ["update", ticket["id"], "--supersedes", "invalid"], 2)["error"] =~
             "supersedes"
  end

  test "a note appends inside Notes without moving subsequent sections", %{root: root} do
    id = call(root, ["new", "Task", "--body", "## Notes\n- old\n\n## Design\nKeep this\n"])["id"]
    result = call(root, ["note", id, "new", "--actor", "pi"])

    assert result["body"] ==
             "## Notes\n- old\n- #{Date.utc_today()} pi: new\n\n## Design\nKeep this\n"
  end

  test "editing one ticket leaves unrelated handwritten YAML byte-for-byte unchanged", %{
    root: root
  } do
    one = call(root, ["new", "One"])["id"]
    two = call(root, ["new", "Two"])["id"]
    path = Path.join([root, "tickets", two <> ".md"])
    hand = File.read!(path) |> String.replace("priority: 2", "priority: 2 # hand comment")
    File.write!(path, hand)
    call(root, ["update", one, "--title", "Changed"])
    assert File.read!(path) == hand
    changed = Path.join([root, "tickets", one <> ".md"])
    before = File.read!(changed)
    call(root, ["update", one, "--title", "Changed"])
    assert File.read!(changed) == before
  end

  test "invalid input fails nonzero, JSON includes a reason, and files remain unchanged", %{
    root: root
  } do
    id = call(root, ["new", "Task"])["id"]
    path = Path.join([root, "tickets", id <> ".md"])
    original = File.read!(path)
    assert call(root, ["update", id, "--priority", "9"], 2)["error"] =~ "priority"
    assert call(root, ["close", id], 2)["error"] =~ "reason"
    assert call(root, ["renumber", id, "../../bad"], 2)["error"] =~ "id"
    assert File.read!(path) == original
    File.write!(path, String.replace(original, "priority: 2", "priority: 9"))
    assert [%{"file" => file, "reason" => reason}] = call(root, ["check"], 2)["errors"]
    assert file == "tickets/#{id}.md"
    assert reason =~ "priority"
  end

  describe "check and added documents" do
    test "output is unchanged when the commit adds no documents", %{root: root} do
      id = call(root, ["new", "Task"])["id"]
      expected = %{"errors" => [], "valid" => true}
      assert call(root, ["check"]) == expected
      assert plain(root, ["check"]) == {"tickets valid\n", 0}

      stage(root, "tickets/#{id}.md")
      stage(root, "lib/code.ex")
      stage(root, "builds/#{id}/report.md")
      assert call(root, ["check"]) == expected
      assert plain(root, ["check"]) == {"tickets valid\n", 0}
    end

    test "a refused add fails with its file and command, plain and --json", %{root: root} do
      File.write!(
        Path.join(root, "config/foreman.toml"),
        "[repos.docs]\nlegacy = [\"slices\"]\n",
        [
          :append
        ]
      )

      stage(root, "slices/new-thing.md")

      assert call(root, ["check"], 2) == %{
               "valid" => false,
               "errors" => [
                 %{
                   "file" => "slices/new-thing.md",
                   "reason" =>
                     "slices/ is a legacy folder: existing files can be edited, new files are refused",
                   "command" => "foreman doc path note <kind> new-thing"
                 }
               ]
             }

      assert plain(root, ["check"]) ==
               {"slices/new-thing.md: slices/ is a legacy folder: existing files can be edited, " <>
                  "new files are refused. Use: foreman doc path note <kind> new-thing\n", 2}
    end

    test "ticket errors and layout errors are reported together", %{root: root} do
      File.mkdir_p!(Path.join(root, "tickets"))
      File.write!(Path.join(root, "tickets/zz-bad.md"), "broken")
      stage(root, "notes.md")
      errors = call(root, ["check"], 2)["errors"]
      assert Enum.map(errors, & &1["file"]) == ["tickets/zz-bad.md", "notes.md"]
    end

    test "unreadable git index skips the layout check with a warning", %{root: root} do
      stage(root, "notes.md")
      File.write!(Path.join(root, ".git/index"), "garbage")
      assert %{"valid" => true, "errors" => [], "warnings" => [warning]} = call(root, ["check"])
      assert warning =~ "document layout check skipped"

      {stdout, stderr, 0} = plain_split(root, ["check"])
      assert stdout == "tickets valid\n"
      assert stderr =~ "warning: document layout check skipped"
    end
  end

  defp plain(root, args) do
    output = capture_io(fn -> send(self(), {:code, Foreman.CLI.run(args, cwd: root)}) end)
    assert_received {:code, code}
    {output, code}
  end

  defp plain_split(root, args) do
    stderr =
      capture_io(:stderr, fn ->
        send(
          self(),
          {:stdout, capture_io(fn -> send(self(), {:code, Foreman.CLI.run(args, cwd: root)}) end)}
        )
      end)

    assert_received {:stdout, stdout}
    assert_received {:code, code}
    {stdout, stderr, code}
  end

  defp stage(root, path) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    unless File.exists?(full), do: File.write!(full, "x\n")
    {_, 0} = System.cmd("git", ["-C", root, "add", "--", path])
  end
end
