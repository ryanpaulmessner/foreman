defmodule Foreman.DocCheckEscriptTest do
  use ExUnit.Case, async: false

  test "the pre-commit hook refuses invented document names and passes layout names" do
    {_, 0} = System.cmd("mix", ["escript.build"], stderr_to_stdout: true)
    executable = Path.expand("foreman")
    base = Path.join(System.tmp_dir!(), "fm-doc-check-cli-#{System.unique_integer([:positive])}")
    root = Path.join(base, "demo")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(base) end)
    {_, 0} = System.cmd("git", ["init", "-q", root])

    env = [
      {"FOREMAN_CONFIG_DIR", Path.join(base, "config")},
      {"FOREMAN_URL", "http://127.0.0.1:1"},
      {"PATH", Path.dirname(executable) <> ":" <> System.get_env("PATH")},
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@t"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@t"}
    ]

    run = fn command, args ->
      System.cmd(command, args, cd: root, env: env, stderr_to_stdout: true)
    end

    write = fn path, text ->
      File.mkdir_p!(Path.dirname(Path.join(root, path))) &&
        File.write!(Path.join(root, path), text)
    end

    # A repo with an old slices/ file, then adopted with slices/ listed as legacy.
    write.("slices/old.md", "old\n")
    {_, 0} = run.("git", ["add", "-A"])
    {_, 0} = run.("git", ["commit", "-qm", "old"])
    {_, 0} = run.(executable, ["adopt", "--json"])

    File.write!(
      Path.join([base, "config", "foreman.toml"]),
      "[repos.docs]\nlegacy = [\"slices\"]\n",
      [
        :append
      ]
    )

    assert File.read!(Path.join(root, ".gitignore")) =~ "builds/*/evidence/"
    {_, 0} = run.("git", ["add", "-A"])
    {_, 0} = run.("git", ["commit", "-qm", "adopt"])

    # A new file in a legacy folder: the hook blocks the commit and names the command.
    write.("slices/new-thing.md", "new\n")
    {_, 0} = run.("git", ["add", "slices/new-thing.md"])
    {output, code} = run.("git", ["commit", "-qm", "new"])
    assert code != 0

    assert output =~
             "slices/new-thing.md: slices/ is a legacy folder: existing files can be edited, " <>
               "new files are refused. Use: foreman doc path note <kind> new-thing"

    {json, 2} = System.cmd(executable, ["check", "--json"], cd: root, env: env)

    assert %{
             "valid" => false,
             "errors" => [%{"command" => "foreman doc path note <kind> new-thing"}]
           } =
             Jason.decode!(json)

    # `commit -a` checks through git's temporary index (GIT_INDEX_FILE) the same way.
    write.("slices/old.md", "edited first\n")
    {output, code} = run.("git", ["commit", "-aqm", "all"])
    assert code != 0
    assert output =~ "slices/new-thing.md: slices/ is a legacy folder"
    {_, 0} = run.("git", ["rm", "-q", "--cached", "slices/new-thing.md"])

    # Editing a legacy file passes.
    write.("slices/old.md", "edited\n")
    {_, 0} = run.("git", ["add", "slices/old.md"])
    {_, 0} = run.("git", ["commit", "-qm", "edit"])

    # An invented name under builds/ is refused; the fixed name passes; evidence is ignored.
    write.("builds/demo-abc/notes.md", "x\n")
    {_, 0} = run.("git", ["add", "builds/demo-abc/notes.md"])
    {output, code} = run.("git", ["commit", "-qm", "notes"])
    assert code != 0
    assert output =~ "builds/demo-abc/notes.md: notes.md is not a fixed name in builds/demo-abc/"
    {_, 0} = run.("git", ["rm", "-qf", "builds/demo-abc/notes.md"])

    write.("builds/demo-abc/report-r2.md", "x\n")
    write.("builds/demo-abc/evidence/shot.png", "x\n")
    {_, 0} = run.("git", ["add", "builds/demo-abc"])
    {status, 0} = run.("git", ["status", "--porcelain"])
    refute status =~ "evidence"
    {_, 0} = run.("git", ["commit", "-qm", "report"])

    # With nothing staged the output is the ticket check alone.
    assert {"tickets valid\n", 0} = System.cmd(executable, ["check"], cd: root, env: env)

    # A linked worktree runs the same hook with its repo's rules.
    worktree = Path.join(base, "demo-wt")
    {_, 0} = run.("git", ["worktree", "add", "-q", "-b", "wt", worktree])
    File.write!(Path.join(worktree, "slices/from-worktree.md"), "x\n")
    wt = fn args -> System.cmd("git", args, cd: worktree, env: env, stderr_to_stdout: true) end
    {_, 0} = wt.(["add", "slices/from-worktree.md"])
    {output, code} = wt.(["commit", "-qm", "wt"])
    assert code != 0
    assert output =~ "slices/from-worktree.md: slices/ is a legacy folder"
  end
end
