defmodule Foreman.MergePolicy do
  @moduledoc """
  Per-repo merge policy. `board` (the default) lets the board merge after confirmation;
  `human` means every change reaches a shared branch through a GitHub PR that a person
  merges: the board never merges, never retargets, and never pushes to the base or the
  default branch. A top-level `merge_policy` sets the default for every repo.
  """

  @doc "Effective policy for a configured repo map, given the loaded config (or nil)."
  def policy(repo, config \\ :current)

  def policy(repo, :current), do: policy(repo, current_config())

  def policy(repo, config) when is_map(repo) do
    repo["merge_policy"] || (is_map(config) && config["merge_policy"]) || "board"
  end

  def human?(repo, config \\ :current), do: is_map(repo) and policy(repo, config) == "human"

  @doc "True when the configured repo `key` is under the human-merge policy."
  def human_key?(key) do
    config = current_config()
    repo = Enum.find((config && config["repos"]) || [], &(&1["key"] == key))
    human?(repo, config)
  end

  @doc "PR base for a repo: `merge_base` when configured, else the forge default branch."
  def base(repo, default_branch), do: (is_map(repo) && repo["merge_base"]) || default_branch

  @doc "Branches a human-merge push may never target: the PR base and the default branch."
  def protected_branches(repo, default_branch),
    do: Enum.uniq(Enum.filter([base(repo, default_branch), default_branch], &is_binary/1))

  defp current_config do
    case Foreman.RuntimeState.config() do
      %{config: config} -> config
      _ -> nil
    end
  end
end
