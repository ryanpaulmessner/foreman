defmodule Foreman.DocCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    root = Path.join(System.tmp_dir!(), "foreman-doc-#{System.unique_integer([:positive])}")
    main = Path.join(root, "main")
    other = Path.join(root, "other")
    work = Path.join(root, "work")
    code = Path.join(work, "ReportSystem")
    for dir <- [main, other, work, code], do: git!(["init", "-q", dir])
    git!(["-C", main, "commit", "-q", "--allow-empty", "-m", "init"])
    git!(["-C", code, "commit", "-q", "--allow-empty", "-m", "init"])
    git!(["-C", code, "remote", "add", "origin", "git@github.com:acme/report-system.git"])
    worktree = Path.join(root, "main-wt")
    git!(["-C", main, "worktree", "add", "-q", "-b", "feat", worktree])
    code_worktree = Path.join(root, "rs-wt")
    git!(["-C", code, "worktree", "add", "-q", "-b", "feat", code_worktree])

    config = Path.join(root, "config")
    File.mkdir_p!(config)
    previous = System.get_env("FOREMAN_CONFIG_DIR")
    System.put_env("FOREMAN_CONFIG_DIR", config)

    File.write!(Path.join(config, "foreman.toml"), """
    [[repos]]
    key = "main"
    path = #{Jason.encode!(main)}
    prefix = "zz"
    tickets = "files"

    [[repos]]
    key = "other"
    path = #{Jason.encode!(other)}
    prefix = "oo"
    tickets = "files"

    [[repos]]
    key = "work"
    path = #{Jason.encode!(work)}
    prefix = "wk"
    tickets = "files"
    github = "acme/report-system"
    code_path = #{Jason.encode!(code)}
    """)

    on_exit(fn ->
      if previous,
        do: System.put_env("FOREMAN_CONFIG_DIR", previous),
        else: System.delete_env("FOREMAN_CONFIG_DIR")

      File.rm_rf!(root)
    end)

    {:ok,
     root: root,
     main: main,
     other: other,
     work: work,
     code: code,
     worktree: worktree,
     code_worktree: code_worktree}
  end

  defp git!(args), do: {_, 0} = System.cmd("git", args, stderr_to_stdout: true)

  # Runs the escript entry point; returns {exit code, stdout, stderr}.
  defp doc(cwd, args, opts \\ []) do
    parent = self()

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            send(parent, {:code, Foreman.CLI.run(["doc" | args], [cwd: cwd] ++ opts)})
          end)

        send(parent, {:stderr, stderr})
      end)

    assert_received {:code, code}
    assert_received {:stderr, stderr}
    {code, stdout, stderr}
  end

  test "report path is in the ticket repo's main checkout from a worktree, another repo and a code checkout",
       %{main: main, other: other, work: work, code: code, worktree: worktree} = ctx do
    for cwd <- [main, worktree, other, Path.join(worktree, "lib/deep") |> tap(&File.mkdir_p!/1)] do
      assert doc(cwd, ["path", "report", "zz-x"]) ==
               {0, Path.join(main, "builds/zz-x/report.md") <> "\n", ""}
    end

    for cwd <- [code, ctx.code_worktree, main] do
      assert doc(cwd, ["path", "report", "wk-8ec.22.1"]) ==
               {0, Path.join(work, "builds/wk-8ec.22.1/report.md") <> "\n", ""}
    end
  end

  test "--json prints the path object", %{main: main, other: other} do
    {0, stdout, ""} = doc(other, ["path", "brief", "zz-x", "--json"])
    assert Jason.decode!(stdout) == %{"path" => Path.join(main, "builds/zz-x/brief.md")}
  end

  test "--next reads the main checkout, not the worktree", %{main: main, worktree: worktree} do
    File.mkdir_p!(Path.join(main, "builds/zz-x"))
    File.write!(Path.join(main, "builds/zz-x/brief.md"), "")
    File.write!(Path.join(main, "builds/zz-x/brief-r2.md"), "")
    File.mkdir_p!(Path.join(worktree, "builds/zz-x"))
    File.write!(Path.join(worktree, "builds/zz-x/brief-r5.md"), "")

    assert doc(worktree, ["path", "brief", "zz-x", "--next"]) ==
             {0, Path.join(main, "builds/zz-x/brief-r3.md") <> "\n", ""}

    assert doc(worktree, ["path", "report", "zz-x", "--next"]) ==
             {0, Path.join(main, "builds/zz-x/report.md") <> "\n", ""}
  end

  test "prints paths only; creates nothing", %{main: main, other: other} do
    {0, _, _} = doc(other, ["path", "evidence", "zz-x"])
    {0, _, _} = doc(main, ["path", "note", "audit", "x"], today: ~D[2026-11-06])
    refute File.exists?(Path.join(main, "builds"))
    refute File.exists?(Path.join(main, "notes"))
  end

  test "note path is today's note in the current repo's main checkout",
       %{main: main, work: work, code: code, worktree: worktree, code_worktree: code_worktree} do
    for {cwd, repo} <- [{main, main}, {worktree, main}, {code, work}, {code_worktree, work}] do
      assert doc(cwd, ["path", "note", "diagnostic", "zoho-timestamps"], today: ~D[2026-11-06]) ==
               {0, Path.join(repo, "notes/2026-11-06-diagnostic-zoho-timestamps.md") <> "\n", ""}
    end
  end

  test "note path defaults to the local date", %{main: main} do
    today = NaiveDateTime.local_now() |> NaiveDateTime.to_date() |> Date.to_iso8601()
    {0, stdout, ""} = doc(main, ["path", "note", "diagnostic", "zoho-timestamps"])
    assert stdout == Path.join(main, "notes/#{today}-diagnostic-zoho-timestamps.md") <> "\n"
  end

  test "unknown note kind or bad slug fails on stderr and lists the allowed kinds", %{main: main} do
    for args <- [["weird-kind", "x"], ["diagnostic", "Zoho_Timestamps"]] do
      {2, "", stderr} = doc(main, ["path", "note" | args])
      assert stderr =~ "error: "
      assert stderr =~ "research, diagnostic, audit, update, message, check, decision, retro"
    end

    {2, stdout, ""} = doc(main, ["path", "note", "weird-kind", "x", "--json"])
    assert Jason.decode!(stdout)["error"] =~ "allowed kinds"
  end

  test "an unknown ticket prefix fails and never guesses a repo", %{main: main} do
    {2, "", stderr} = doc(main, ["path", "report", "nope-x"])
    assert stderr =~ ~s(no registered repo has ticket prefix "nope")
    assert stderr =~ "oo, wk, zz"
  end

  test "a note outside a registered repo fails", %{root: root} do
    outside = Path.join(root, "outside")
    git!(["init", "-q", outside])
    {2, "", stderr} = doc(outside, ["path", "note", "audit", "x"])
    assert stderr =~ "not in a registered repo"
    {2, "", stderr} = doc(root, ["path", "note", "audit", "x"])
    assert stderr =~ "not in a registered repo"
  end

  test "unknown kind, bad id and bad usage fail with exit 2", %{main: main} do
    {2, "", stderr} = doc(main, ["path", "notes", "zz-x"])
    assert stderr =~ "brief, message, report, review, loop, pr, plan, evidence"
    {2, "", stderr} = doc(main, ["path", "report", "zz-../x"])
    assert stderr =~ "invalid ticket id"

    for args <- [
          [],
          ["path"],
          ["path", "report"],
          ["index"],
          ["path", "note", "audit", "x", "--next"],
          ["path", "report", "zz-x", "--bogus"]
        ] do
      {2, "", stderr} = doc(main, args)
      assert stderr =~ "usage: foreman doc path", inspect(args)
    end
  end

  test "an unexpected failure exits 2 on stderr, never a stdout warning", %{main: main} do
    {2, "", stderr} = doc(main, ["path", "note", "audit", "x"], today: :not_a_date)
    assert stderr =~ "error: doc path failed"
  end
end
