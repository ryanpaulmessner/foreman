defmodule Foreman.Requests.PushJob do
  @moduledoc "One-shot push: commit the request start audit before IO; never replay an executing attempt."
  use Oban.Worker, queue: :external_writes, max_attempts: 1
  alias Foreman.{Requests, Overlay}
  alias Foreman.Requests.{Push, LocalRefs}

  @impl true
  def timeout(_), do: :timer.seconds(60)
  @impl true
  def perform(%Oban.Job{args: %{"request_id" => id}}), do: run(id)

  def run(id, opts \\ []) do
    case Requests.resolve(id, :start, %{}) do
      {:ok, %{kind: "push", state: "executing"} = request} ->
        execute(request, opts)

      _ ->
        Requests.resolve(id, :orphaned, %{})
        :ok
    end
  end

  defp execute(request, opts) do
    adapter = Keyword.get(opts, :adapter, Foreman.Forge.adapter())
    facts = request.facts

    result =
      with :ok <- Foreman.Preview.allow_external_write(),
           forge_options = Keyword.get_lazy(opts, :forge_options, &Foreman.Forge.options/0),
           true <- adapter.capabilities().write || {:error, :read_only},
           {:ok, repo} <- Push.configured(request.repo_key),
           true <- repo["github"] == facts["remote"] || {:error, :config_changed},
           :ok <- Push.shape(facts),
           :ok <- LocalRefs.same_repo(facts["worktree"], Foreman.CodeCheckout.path(repo)),
           {:ok, snapshot} <- adapter.list(facts["remote"], forge_options),
           {:ok, current_repo} <- Push.configured(request.repo_key),
           true <- current_repo == repo || {:error, :config_changed},
           %{stage: stage} = row when stage in [:committed, :pr_open] <-
             Overlay.get({request.repo_key, request.bead_id}),
           :ok <- Push.update_rule(facts, snapshot, stage),
           :ok <- Push.default_rule(facts, row, snapshot["default_branch"]),
           :ok <- Push.human_rule(facts, current_repo, snapshot["default_branch"]),
           :ok <- LocalRefs.safe_config(facts["worktree"]),
           :ok <- Push.unchanged(facts) do
        push(facts, forge_options, opts)
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :not_committed}
      end

    case result do
      :ok ->
        Foreman.Forge.Store.record_push(request.repo_key, facts)
        Requests.resolve(request.id, :succeeded, %{"result" => %{"sha" => facts["expected_sha"]}})

      {:error, reason} ->
        Requests.resolve(request.id, :failed, %{"reason" => to_string(reason)})
    end

    :ok
  rescue
    _ ->
      Requests.resolve(request.id, :failed, %{"reason" => "outcome unknown"})
      :ok
  end

  defp push(facts, forge_options, opts) do
    lease =
      if facts["expected_old_head"],
        do: [
          "--force-with-lease=refs/heads/#{facts["remote_branch"]}:#{facts["expected_old_head"]}"
        ],
        else: []

    args =
      [
        "-c",
        "credential.helper=",
        "-c",
        "credential.helper=!gh auth git-credential",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "push.followTags=false",
        "-c",
        "push.negotiate=false",
        "-c",
        "http.followRedirects=false",
        "push",
        "--porcelain",
        "--no-verify"
      ] ++
        lease ++
        [
          "--",
          "https://github.com/" <> facts["remote"] <> ".git",
          facts["expected_sha"] <> ":refs/heads/" <> facts["remote_branch"]
        ]

    command = Keyword.get(opts, :command, &System.cmd("git", &1, &2))

    cleared =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(
        &(String.starts_with?(&1, "GIT_") or &1 in ["GH_DEBUG", "GITHUB_TOKEN", "GH_HOST"])
      )
      |> Enum.map(&{&1, nil})

    env =
      cleared ++
        [
          {"GIT_TERMINAL_PROMPT", "0"},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_NO_REPLACE_OBJECTS", "1"},
          {"GIT_GRAFT_FILE", "/dev/null"},
          {"GH_TOKEN", forge_options[:token]}
        ]

    with :ok <- fast_forward(facts, env, command) do
      send_push(command, args, facts, env)
    end
  end

  defp fast_forward(%{"expected_old_head" => old} = facts, env, command) when is_binary(old) do
    if facts["force_with_lease"] == true do
      :ok
    else
      case command.(["merge-base", "--is-ancestor", old, facts["expected_sha"]],
             cd: facts["worktree"],
             env: env,
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        {_, 1} ->
          {:error, "not a fast-forward; use --force-with-lease to replace the branch history"}

        _ ->
          {:error, "the old head #{old} is not in this worktree; fetch it first"}
      end
    end
  end

  defp fast_forward(_, _, _), do: :ok

  defp send_push(command, args, facts, env) do
    case command.(args, cd: facts["worktree"], env: env, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        if String.contains?(output, ["non-fast-forward", "fetch first"]),
          do: {:error, "not a fast-forward"},
          else: {:error, "outcome unknown"}
    end
  end
end
