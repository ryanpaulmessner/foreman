defmodule Foreman.AdoptTest do
  use ExUnit.Case, async: true

  setup do
    base = Path.join(System.tmp_dir!(), "fm-adopt-test-#{System.unique_integer([:positive])}")
    root = Path.join(base, "demo")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q", root])
    System.cmd("git", ["-C", root, "remote", "add", "origin", "git@github.com:owner/demo.git"])
    on_exit(fn -> File.rm_rf!(base) end)
    %{root: root, config: Path.join(base, "config")}
  end

  test "adopts an empty repo, repairs missing pieces, then does nothing", %{
    root: root,
    config: config
  } do
    File.write!(Path.join(root, "AGENTS.md"), "# Keep me\n")
    assert {:ok, first} = Foreman.Adopt.run(root, config_dir: config)
    assert first.changes != []
    assert File.dir?(Path.join(root, "tickets"))
    assert File.read!(Path.join(root, "AGENTS.md")) =~ "# Keep me"
    assert File.read!(Path.join(root, ".foreman/hooks/pre-commit")) =~ "foreman check"
    assert {:ok, %{changes: []}} = Foreman.Adopt.run(root, config_dir: config)
    File.rm!(Path.join(root, ".foreman/hooks/pre-commit"))

    assert {:ok, %{changes: [".foreman/hooks/pre-commit"]}} =
             Foreman.Adopt.run(root, config_dir: config)
  end

  test "new AGENTS block points document writers to the foreman Documents section", %{
    root: root,
    config: config
  } do
    assert {:ok, _} = Foreman.Adopt.run(root, config_dir: config)
    [_, block] = String.split(File.read!(Path.join(root, "AGENTS.md")), "<!-- BEGIN FOREMAN -->")

    assert block =~
             "Documents: follow the `foreman` skill's Documents section before writing a document."
  end

  test "ignores build evidence in .gitignore, keeping existing lines, once", %{
    root: root,
    config: config
  } do
    gitignore = Path.join(root, ".gitignore")
    File.write!(gitignore, "/_build\n/deps")
    assert {:ok, first} = Foreman.Adopt.run(root, config_dir: config)
    assert ".gitignore" in first.changes
    assert File.read!(gitignore) == "/_build\n/deps\nbuilds/*/evidence/\n"
    assert {:ok, %{changes: []}} = Foreman.Adopt.run(root, config_dir: config)

    File.rm!(gitignore)
    assert {:ok, %{changes: [".gitignore"]}} = Foreman.Adopt.run(root, config_dir: config)
    assert File.read!(gitignore) == "builds/*/evidence/\n"

    File.write!(gitignore, "# docs\n/builds/*/evidence/\n")
    assert {:ok, %{changes: []}} = Foreman.Adopt.run(root, config_dir: config)
    assert File.read!(gitignore) == "# docs\n/builds/*/evidence/\n"
  end

  test "preserves custom hooks and removes marked beads instructions", %{
    root: root,
    config: config
  } do
    File.write!(
      Path.join(root, "AGENTS.md"),
      "# Mine\n<!-- BEGIN BEADS -->\nuse bd\n<!-- END BEADS -->\n"
    )

    hook =
      "#!/bin/sh\n# --- BEGIN HOUSE BEADS EXPORT ---\nbd export\n# --- END HOUSE BEADS EXPORT ---\necho custom\n"

    File.write!(Path.join(root, ".git/hooks/pre-commit"), hook)
    File.chmod!(Path.join(root, ".git/hooks/pre-commit"), 0o755)
    assert {:ok, _} = Foreman.Adopt.run(root, config_dir: config)
    assert File.read!(Path.join(root, ".foreman/hooks/pre-commit")) =~ "echo custom"
    refute File.read!(Path.join(root, ".git/hooks/pre-commit")) =~ "bd export"
    refute File.read!(Path.join(root, "AGENTS.md")) =~ "use bd"
  end

  test "refuses a symlinked beads export without removing its directory", %{
    root: root,
    config: config
  } do
    File.mkdir_p!(Path.join(root, ".beads"))
    outside = Path.join(Path.dirname(root), "source.jsonl")
    File.write!(outside, "")
    File.ln_s!(outside, Path.join(root, ".beads/issues.jsonl"))
    assert {:error, _} = Foreman.Adopt.run(root, config_dir: config)
    assert File.dir?(Path.join(root, ".beads"))
    refute File.exists?(Path.join(config, "foreman.toml"))
  end

  test "keeps a registered repo identity when its key differs from the directory name", %{
    root: root,
    config: config
  } do
    File.mkdir_p!(config)
    path = Path.join(config, "foreman.toml")

    text =
      "[[repos]]\nkey = \"stable-board-key\"\npath = #{Jason.encode!(root)}\nprefix = \"dm\"\ntickets = \"files\"\ngithub = \"owner/demo\"\n"

    File.write!(path, text)
    assert {:ok, result} = Foreman.Adopt.run(root, config_dir: config)
    assert result.entry["key"] == "stable-board-key"
    assert result.entry["prefix"] == "dm"
    assert File.read!(path) == text
    assert {:ok, %{changes: []}} = Foreman.Adopt.run(root, config_dir: config)
  end

  test "refuses redirected beads stores rather than migrating a stale export", %{
    root: root,
    config: config
  } do
    File.mkdir_p!(Path.join(root, ".beads"))
    File.write!(Path.join(root, ".beads/issues.jsonl"), "")
    File.write!(Path.join(root, ".beads/redirect"), "/elsewhere/.beads")
    assert {:error, _} = Foreman.Adopt.run(root, config_dir: config)
    assert File.exists?(Path.join(root, ".beads/redirect"))
  end

  test "preserves beads and existing tickets when publication cannot be verified", %{
    root: root,
    config: config
  } do
    File.mkdir_p!(Path.join(root, ".beads"))
    File.write!(Path.join(root, ".beads/issues.jsonl"), "")
    File.mkdir_p!(Path.join(root, "tickets"))
    File.write!(Path.join(root, "tickets/demo-a.md"), "handwritten invalid ticket")
    assert {:error, _} = Foreman.Adopt.run(root, config_dir: config)
    assert File.exists?(Path.join(root, ".beads/issues.jsonl"))
    assert File.read!(Path.join(root, "tickets/demo-a.md")) == "handwritten invalid ticket"
    assert [_backup] = Path.wildcard(Path.join(config, "backups/*.tar.gz"))
    refute File.exists?(Path.join(config, "foreman.toml"))
  end

  test "retains beads when a concurrent writer changes non-issue data after backup", %{
    root: root,
    config: config
  } do
    File.mkdir_p!(Path.join(root, ".beads"))

    record = %{
      "id" => "dm-a",
      "title" => "A",
      "issue_type" => "task",
      "status" => "open",
      "priority" => 2,
      "created_at" => "2026-01-01"
    }

    File.write!(Path.join(root, ".beads/issues.jsonl"), Jason.encode!(record) <> "\n")
    ticket_path = Path.join(root, "tickets/dm-a.md")

    Mimic.stub(File, :read, fn path ->
      result = Mimic.call_original(File, :read, [path])

      if path == ticket_path and match?({:ok, _}, result),
        do: File.write!(Path.join(root, ".beads/late-data"), "preserve me")

      result
    end)

    assert {:error, reason} = Foreman.Adopt.run(root, config_dir: config)
    assert reason =~ "beads changed"
    assert File.read!(Path.join(root, ".beads/late-data")) == "preserve me"
  end

  test "does not activate a disabled unrelated hook", %{root: root, config: config} do
    File.write!(Path.join(root, ".git/hooks/pre-push"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(root, ".git/hooks/pre-push"), 0o644)
    assert {:ok, _} = Foreman.Adopt.run(root, config_dir: config)

    assert Bitwise.band(File.stat!(Path.join(root, ".foreman/hooks/pre-push")).mode, 0o777) ==
             0o644
  end

  test "keeps a disabled pre-commit disabled while installing the check", %{
    root: root,
    config: config
  } do
    File.write!(Path.join(root, ".git/hooks/pre-commit"), "#!/bin/sh\nexit 77\n")
    File.chmod!(Path.join(root, ".git/hooks/pre-commit"), 0o644)
    assert {:ok, _} = Foreman.Adopt.run(root, config_dir: config)
    refute File.read!(Path.join(root, ".foreman/hooks/pre-commit")) =~ "exit 77"
    assert File.read!(Path.join(root, ".foreman/hooks/pre-commit.disabled")) =~ "exit 77"
  end

  test "backs up and compares every ticket before removing beads", %{root: root, config: config} do
    File.mkdir_p!(Path.join(root, ".beads"))

    export =
      Jason.encode!(%{
        "id" => "dm-a",
        "title" => "Done",
        "issue_type" => "task",
        "status" => "closed",
        "priority" => 2,
        "created_at" => "2026-01-01T00:00:00Z",
        "closed_at" => "2026-01-02T00:00:00Z",
        "comment_count" => 0
      }) <> "\n"

    File.write!(Path.join(root, ".beads/issues.jsonl"), export)
    assert {:ok, result} = Foreman.Adopt.run(root, config_dir: config)
    assert result.comparison == %{count: 1, comments: 0}
    assert File.regular?(result.backup)
    assert Map.has_key?(result, :export)

    assert File.read!(result.export) |> Foreman.BeadsConversion.decode() ==
             Foreman.BeadsConversion.decode(export)

    refute String.starts_with?(result.backup, root <> "/")
    refute File.exists?(Path.join(root, ".beads"))
    assert Foreman.TicketStore.check(root) == []
    assert {:ok, %{changes: []}} = Foreman.Adopt.run(root, config_dir: config)
  end
end
