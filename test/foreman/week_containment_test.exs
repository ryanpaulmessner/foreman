defmodule Foreman.Week.ContainmentTest do
  use ExUnit.Case, async: true
  alias Foreman.Week.Containment

  test "fetch rejects a directory inside another checkout without touching its fetch state" do
    path = Path.join(System.tmp_dir!(), "week-parent-#{System.unique_integer([:positive])}")
    child = Path.join(path, "child")
    File.mkdir_p!(child)
    on_exit(fn -> File.rm_rf!(path) end)
    assert {_, 0} = System.cmd("git", ["init", "-b", "production", path])
    marker = Path.join(path, ".git/FETCH_HEAD")
    File.write!(marker, "unchanged")
    assert {:error, :invalid_checkout} = Containment.fetch(child)
    assert File.read!(marker) == "unchanged"
  end

  test "merge heads reach staging then production; squash heads are not contained" do
    path = Path.join(System.tmp_dir!(), "week-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    git = fn args ->
      {output, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
      String.trim(output)
    end

    git.(["init", "-b", "production"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "Test"])
    git.(["commit", "--allow-empty", "-m", "initial"])
    git.(["checkout", "-b", "staging"])
    git.(["checkout", "-b", "feature"])
    File.write!(Path.join(path, "feature"), "one")
    git.(["add", "."])
    git.(["commit", "-m", "feature"])
    first = git.(["rev-parse", "HEAD"])
    git.(["checkout", "staging"])
    git.(["merge", "--no-ff", "feature", "-m", "merge feature"])
    git.(["checkout", "production"])
    git.(["merge", "--no-ff", "staging", "-m", "deploy"])
    git.(["checkout", "-b", "second", "staging"])
    git.(["commit", "--allow-empty", "-m", "second"])
    second = git.(["rev-parse", "HEAD"])
    git.(["checkout", "staging"])
    git.(["merge", "--no-ff", "second", "-m", "merge second"])
    git.(["checkout", "-b", "squash"])
    File.write!(Path.join(path, "squash"), "two")
    git.(["add", "."])
    git.(["commit", "-m", "squash feature"])
    squash = git.(["rev-parse", "HEAD"])
    git.(["checkout", "staging"])
    git.(["merge", "--squash", "squash"])
    git.(["commit", "-m", "squashed"])

    for branch <- ~w(staging production) do
      git.(["update-ref", "refs/remotes/origin/#{branch}", branch])
    end

    # Local names must not shadow the remote-tracking refs.
    git.(["branch", "origin/production", "staging"])
    git.(["branch", "origin/staging", "production"])

    assert {:ok, %{in_production: true, in_staging: true}} = Containment.check(path, first)
    assert {:ok, %{in_production: false, in_staging: true}} = Containment.check(path, second)
    assert {:ok, %{in_production: false, in_staging: false}} = Containment.check(path, squash)
    # A deleted squash branch may leave no head object in this checkout.
    assert {:ok, %{in_production: false, in_staging: false}} =
             Containment.check(path, String.duplicate("f", 40))

    assert {_, 0} =
             System.cmd(
               "git",
               ["merge-base", "--is-ancestor", first, "refs/remotes/origin/production"],
               cd: path
             )
  end
end
