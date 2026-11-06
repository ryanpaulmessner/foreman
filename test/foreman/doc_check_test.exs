defmodule Foreman.DocCheckTest do
  use ExUnit.Case, async: true
  alias Foreman.DocCheck

  setup do
    base = Path.join(System.tmp_dir!(), "fm-doc-check-#{System.unique_integer([:positive])}")
    root = Path.join(base, "repo")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(base) end)
    git!(root, ["init", "-q"])
    write(root, "slices/old.md", "old\n")
    write(root, "docs/gone.md", "gone\n")
    write(root, "docs/moved.md", "moved\n")
    git!(root, ["add", "-A"])
    commit!(root)
    %{root: root, config: Path.join(base, "config")}
  end

  describe "added documents" do
    test "only staged adds count; renames count at the new path; edits and deletes pass", %{
      root: root
    } do
      write(root, "slices/old.md", "edited\n")
      File.rm!(Path.join(root, "docs/gone.md"))
      git!(root, ["mv", "docs/moved.md", "slices/renamed.md"])
      write(root, "notes/staged.md", "x\n")
      write(root, "notes/unstaged.md", "x\n")
      write(root, "lib/code.ex", "x\n")
      write(root, "mockup/page.HTML", "x\n")
      git!(root, ["add", "slices/old.md", "docs/gone.md", "notes/staged.md"])
      git!(root, ["add", "lib/code.ex", "mockup/page.HTML"])

      assert DocCheck.added_documents(root) ==
               {:ok, ["mockup/page.HTML", "notes/staged.md", "slices/renamed.md"]}
    end

    test "renames are adds even when git config detects copies", %{root: root} do
      git!(root, ["config", "diff.renames", "copies"])
      git!(root, ["mv", "slices/old.md", "slices/new.md"])
      assert DocCheck.added_documents(root) == {:ok, ["slices/new.md"]}
    end

    test "nothing staged reports nothing", %{root: root, config: config} do
      write(root, "notes/untracked.md", "x\n")
      assert DocCheck.added_documents(root) == {:ok, []}
      assert DocCheck.check(root, config_dir: config) == %{errors: [], warnings: []}
    end

    test "a first commit on an unborn branch checks its adds" do
      root = Path.join(System.tmp_dir!(), "fm-doc-unborn-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      git!(root, ["init", "-q"])
      write(root, "notes/x.md", "x\n")
      git!(root, ["add", "-A"])
      assert DocCheck.added_documents(root) == {:ok, ["notes/x.md"]}
    end

    test "a linked worktree checks its own index", %{root: root} do
      worktree = root <> "-wt"
      on_exit(fn -> File.rm_rf!(worktree) end)
      git!(root, ["worktree", "add", "-q", "-b", "wt", worktree])
      stage(worktree, "notes/in-worktree.md")
      stage(root, "notes/in-main.md")
      assert DocCheck.added_documents(worktree) == {:ok, ["notes/in-worktree.md"]}
    end

    test "unreadable git skips the layout check with a warning", %{config: config} do
      root = Path.join(System.tmp_dir!(), "fm-doc-nogit-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      assert %{errors: [], warnings: [warning]} = DocCheck.check(root, config_dir: config)
      assert warning =~ "layout check skipped"
    end
  end

  describe "[docs] config" do
    test "an unregistered repo or an entry without docs has no rules", %{
      root: root,
      config: config
    } do
      assert DocCheck.rules(root, config_dir: config) ==
               {:ok, allow: [], legacy: [], prefixes: []}

      register(root, config, "")

      assert DocCheck.rules(root, config_dir: config) ==
               {:ok, allow: [], legacy: [], prefixes: ["zz"]}
    end

    test "reads allow globs and legacy folders from the repo's entry in foreman.toml", %{
      root: root,
      config: config
    } do
      register(
        root,
        config,
        "[repos.docs]\nallow = [\"skills/**\"]\nlegacy = [\"slices\", \"epics/\"]\n"
      )

      assert DocCheck.rules(root, config_dir: config) ==
               {:ok, allow: ["skills/**"], legacy: ["slices", "epics/"], prefixes: ["zz"]}
    end

    test "a linked worktree gets its repo's rules", %{root: root, config: config} do
      register(root, config, "docs = { legacy = [\"slices\"] }\n")
      worktree = root <> "-wt"
      git!(root, ["worktree", "add", "-q", "-b", "wt", worktree])
      assert {:ok, rules} = DocCheck.rules(worktree, config_dir: config)
      assert rules[:legacy] == ["slices"]
    end

    test "wrong types and unknown keys are config errors", %{root: root, config: config} do
      register(root, config, "[repos.docs]\nallow = \"skills/**\"\n")
      assert {:error, reason} = DocCheck.rules(root, config_dir: config)
      assert reason =~ "docs.allow"

      register(root, config, "[repos.docs]\nlegasy = [\"slices\"]\n")
      assert {:error, reason} = DocCheck.rules(root, config_dir: config)
      assert reason =~ "docs.legasy"
    end

    test "a broken config fails the check only when documents are added", %{
      root: root,
      config: config
    } do
      File.mkdir_p!(config)
      File.write!(Path.join(config, "foreman.toml"), "[repos\n")
      assert DocCheck.check(root, config_dir: config) == %{errors: [], warnings: []}
      stage(root, "builds/zz-1/report.md")

      assert %{errors: [%{file: "foreman.toml", reason: reason}]} =
               DocCheck.check(root, config_dir: config)

      assert reason =~ "invalid TOML"
    end
  end

  describe "check" do
    test "a new file in a legacy folder is refused with the command; an edit passes", %{
      root: root,
      config: config
    } do
      register(root, config, "docs = { legacy = [\"slices\"] }\n")
      write(root, "slices/old.md", "edited\n")
      git!(root, ["add", "slices/old.md"])
      assert DocCheck.check(root, config_dir: config) == %{errors: [], warnings: []}

      stage(root, "slices/new-thing.md")

      assert DocCheck.check(root, config_dir: config).errors == [
               %{
                 file: "slices/new-thing.md",
                 reason:
                   "slices/ is a legacy folder: existing files can be edited, new files are refused",
                 command: "foreman doc path note <kind> new-thing"
               }
             ]
    end

    test "a name a legacy file suggests becomes a ticket command", %{root: root, config: config} do
      register(root, config, "docs = { legacy = [\"slices\"] }\n")
      write(root, "tickets/work-8ec.22.3.md", "x\n")
      stage(root, "slices/support-board/work-8ec.22.3-prompt.md")

      assert [%{command: "foreman doc path brief work-8ec.22.3 --next"}] =
               DocCheck.check(root, config_dir: config).errors
    end

    test "builds/ accepts fixed names only", %{root: root, config: config} do
      stage(root, "builds/work-abc/report-r2.md")
      assert DocCheck.check(root, config_dir: config) == %{errors: [], warnings: []}

      stage(root, "builds/work-abc/notes.md")

      assert DocCheck.check(root, config_dir: config).errors == [
               %{
                 file: "builds/work-abc/notes.md",
                 reason: "notes.md is not a fixed name in builds/work-abc/",
                 command: "foreman doc path <kind> work-abc"
               }
             ]
    end

    test "README, AGENTS, CLAUDE and CHANGELOG pass anywhere; allow globs pass", %{
      root: root,
      config: config
    } do
      for name <- ~w(README.md AGENTS.md CLAUDE.md CHANGELOG.md) do
        stage(root, name)
        stage(root, "deep/inside/#{name}")
        stage(root, "slices/x/#{name}")
      end

      register(root, config, "docs = { allow = [\"skills/**\"], legacy = [\"slices\"] }\n")
      stage(root, "skills/foreman/SKILL.md")
      stage(root, "skills/foreman/ref/page.html")
      assert DocCheck.check(root, config_dir: config) == %{errors: [], warnings: []}

      stage(root, "skillz/x.md")
      assert [%{file: "skillz/x.md"}] = DocCheck.check(root, config_dir: config).errors
    end

    test "only .md and .html files are checked", %{root: root, config: config} do
      stage(root, "random/data.csv")
      stage(root, "random/image.png")
      assert DocCheck.check(root, config_dir: config) == %{errors: [], warnings: []}
      stage(root, "random/page.html")
      assert [%{file: "random/page.html"}] = DocCheck.check(root, config_dir: config).errors
    end

    test "errors are sorted by file and each is reported once", %{root: root, config: config} do
      stage(root, "b.md")
      stage(root, "a.md")
      assert [%{file: "a.md"}, %{file: "b.md"}] = DocCheck.check(root, config_dir: config).errors
    end
  end

  defp register(root, config, extra) do
    File.mkdir_p!(config)

    File.write!(
      Path.join(config, "foreman.toml"),
      "[[repos]]\nkey = \"sample\"\npath = #{Jason.encode!(root)}\nprefix = \"zz\"\n" <> extra
    )
  end

  defp stage(root, path) do
    write(root, path, "x\n")
    git!(root, ["add", "--", path])
  end

  defp write(root, path, text) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp commit!(root),
    do: git!(root, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end
end
