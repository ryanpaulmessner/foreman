defmodule Foreman.TicketFilesTest do
  use ExUnit.Case, async: true
  alias Foreman.TicketFiles

  setup do
    root = Path.join(System.tmp_dir!(), "fm-reader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "tickets"))
    System.cmd("git", ["init", "-q", root])
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "tickets/demo-abc.md")}
  end

  def text(title) do
    Foreman.TicketFile.print(%{
      facts: %{
        "id" => "demo-abc",
        "title" => title,
        "type" => "task",
        "status" => "open",
        "priority" => 2,
        "parent" => nil,
        "blocked_by" => ["demo-def"],
        "related" => [],
        "discovered_from" => nil,
        "labels" => ["reader"],
        "created" => "2026-10-18",
        "closed" => nil,
        "close_reason" => nil
      },
      body: "## What to build\nBody\n\n## Acceptance\n- [x] First\n- [ ] Second\n"
    })
  end

  test "parked file facts reach the board projection unchanged" do
    parked =
      text("Wait")
      |> String.replace("status: open", "status: parked")
      |> String.replace(
        "close_reason: null",
        "close_reason: null\nparked_reason: Vendor approval\nparked: 2026-10-19"
      )

    assert {[raw], []} = TicketFiles.decode(%{"demo-abc.md" => {:ok, parked}}, [])
    assert raw["status"] == "parked"
    assert raw["parked_reason"] == "Vendor approval"
    assert raw["parked"] == "2026-10-19"
  end

  test "malformed files retain their last good row and name the error", %{root: root, path: path} do
    File.write!(path, text("Good"))
    {:ok, snapshot} = TicketFiles.snapshot(root)
    {[good], []} = TicketFiles.decode(snapshot, [])
    File.write!(path, "---\ninvalid: true\n---\n")
    {:ok, snapshot} = TicketFiles.snapshot(root)
    assert {[^good], [error]} = TicketFiles.decode(snapshot, [good])
    assert error =~ "tickets/demo-abc.md: unknown keys"
  end

  test "linked worktree resolves the main checkout", %{root: root} do
    checkout = root <> "-linked"
    on_exit(fn -> File.rm_rf!(checkout) end)

    {_, 0} =
      System.cmd("git", ["-C", root, "worktree", "add", "--orphan", "-b", "scratch", checkout],
        stderr_to_stdout: true
      )

    assert {:ok, ^root} = TicketFiles.main_checkout(checkout)
  end

  test "an active CLI publication cannot be mistaken for deletions", %{root: root} do
    File.mkdir_p!(Path.join(root, ".git/.foreman-write-lock"))
    assert {:error, error} = TicketFiles.snapshot(root)
    assert error =~ "write in progress"
  end

  test "create, edit, atomic editor save and delete are reflected by rescanning", %{
    root: root,
    path: path
  } do
    File.write!(path, text("First"))
    assert {:ok, snapshot} = TicketFiles.snapshot(root)
    assert {[raw], []} = TicketFiles.decode(snapshot, [])
    assert raw["title"] == "First"
    assert raw["description"] == "## What to build\nBody"
    assert raw["acceptance_progress"] == %{"checked" => 1, "total" => 2}
    assert raw["dependencies"] == [%{"depends_on_id" => "demo-def", "type" => "blocks"}]
    File.write!(path, text("Edited"))
    assert {:ok, snapshot} = TicketFiles.snapshot(root)
    assert {[edited], []} = TicketFiles.decode(snapshot, [raw])
    assert edited["title"] == "Edited"
    File.write!(path <> ".tmp", text("Renamed"))
    File.rename!(path <> ".tmp", path)
    assert {:ok, snapshot} = TicketFiles.snapshot(root)
    assert {[renamed], []} = TicketFiles.decode(snapshot, [edited])
    assert renamed["title"] == "Renamed"
    File.rm!(path)
    assert {:ok, snapshot} = TicketFiles.snapshot(root)
    assert {[], []} = TicketFiles.decode(snapshot, [renamed])
  end
end
