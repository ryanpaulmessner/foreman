defmodule Foreman.Requests.TryItGate do
  @moduledoc "A push needs a tried UI tree only when its own change touches configured UI paths."
  import Ecto.Query
  alias Foreman.Requests.{LocalRefs, OpenPr, Request}

  def validate(%{"no_try_it" => reason}, _, _, _) when is_binary(reason), do: :ok

  def validate(facts, row, %{"try_it" => %{"paths" => [_ | _] = paths}} = repo, snapshot) do
    base =
      List.first(
        OpenPr.stack_bases(snapshot, facts["remote_branch"], {row.repo_key, row.bead_id})
      ) ||
        Foreman.MergePolicy.base(repo, snapshot["default_branch"])

    with :ok <- LocalRefs.safe_config(facts["worktree"]),
         {:ok, base_sha} <- base_sha(facts["worktree"], base, snapshot),
         {:ok, ancestor} <-
           git(facts["worktree"], ["merge-base", base_sha, facts["expected_sha"]]),
         {:ok, files} <- changed(facts, String.trim(ancestor), paths) do
      if files == [] or covered?(facts, row.repo_key, paths),
        do: :ok,
        else: missing(row.bead_id, files)
    end
  end

  def validate(_, _, _, _), do: :ok

  defp covered?(facts, repo_key, paths) do
    reviews =
      Foreman.Repo.all(
        from r in Request,
          where:
            r.repo_key == ^repo_key and r.kind == "review_ui" and r.state == "answered" and
              fragment("?->>'answer'", r.outcome) == "Works",
          select: r.facts
      )

    Enum.any?(reviews, fn review ->
      Foreman.Requests.Decision.text?(review["url"]) and
        match?({:ok, _}, LocalRefs.sha(review["sha"])) and
        changed(facts, review["sha"], paths) == {:ok, []}
    end)
  end

  defp base_sha(path, base, snapshot) do
    case get_in(snapshot, ["branches", base]) do
      nil -> LocalRefs.branch(path, base)
      sha -> LocalRefs.sha(sha)
    end
  end

  defp changed(facts, from, paths) do
    with {:ok, output} <-
           git(facts["worktree"], [
             "diff",
             "--no-ext-diff",
             "--no-textconv",
             "--no-renames",
             "--name-only",
             "-z",
             from,
             facts["expected_sha"],
             "--"
           ]) do
      {:ok,
       output
       |> String.split(<<0>>, trim: true)
       |> Enum.filter(fn file -> Enum.any?(paths, &Foreman.DocLayout.glob?(&1, file)) end)}
    end
  end

  defp git(path, args) do
    env = for {key, _} <- System.get_env(), String.starts_with?(key, "GIT_"), do: {key, nil}

    env =
      env ++
        [
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_NO_REPLACE_OBJECTS", "1"},
          {"GIT_GRAFT_FILE", "/dev/null"},
          {"GIT_TERMINAL_PROMPT", "0"}
        ]

    case System.cmd("git", ["-c", "advice.graftFileDeprecated=false" | args],
           cd: path,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      _ -> {:error, :try_it_diff_failed}
    end
  end

  defp missing(ticket, files) do
    {:error,
     %{
       error: "try_it_missing",
       message:
         "#{ticket} changes #{length(files)} UI files (#{Enum.join(Enum.take(files, 3), ", ")}). Post a review_ui card with --url, --walkthrough and --sha, or pass --no-try-it \"<reason>\"."
     }}
  end
end
