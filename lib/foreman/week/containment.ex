defmodule Foreman.Week.Containment do
  @moduledoc "Read-only ancestry checks against remote tracking refs."

  def check(path, sha) do
    if is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      with {:ok, production} <- ancestor(path, sha, "production"),
           {:ok, staging} <- ancestor(path, sha, "staging") do
        {:ok, %{in_production: production, in_staging: staging}}
      end
    else
      {:error, :invalid_sha}
    end
  end

  def fetch(path) do
    with :ok <- checkout_root(path) do
      fetch_refs(path)
    end
  rescue
    _ -> {:error, :fetch_failed}
  end

  defp checkout_root(path) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"],
           cd: path,
           stderr_to_stdout: true,
           env: [{"GIT_CEILING_DIRECTORIES", Path.dirname(Path.expand(path))}]
         ) do
      {root, 0} ->
        if String.trim(root) == Path.expand(path), do: :ok, else: {:error, :invalid_checkout}

      _ ->
        {:error, :invalid_checkout}
    end
  end

  defp fetch_refs(path) do
    case System.cmd(
           "git",
           [
             "-c",
             "gc.auto=0",
             "-c",
             "maintenance.auto=false",
             "-c",
             "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=15",
             "-c",
             "http.lowSpeedLimit=1",
             "-c",
             "http.lowSpeedTime=30",
             "fetch",
             "--refmap=+refs/heads/*:refs/remotes/origin/*",
             "origin",
             "production",
             "staging"
           ],
           cd: path,
           stderr_to_stdout: true,
           env: [
             {"GIT_TERMINAL_PROMPT", "0"},
             {"GIT_CEILING_DIRECTORIES", Path.dirname(Path.expand(path))}
           ]
         ) do
      {_, 0} -> :ok
      _ -> {:error, :fetch_failed}
    end
  rescue
    _ -> {:error, :fetch_failed}
  end

  defp ancestor(path, sha, branch) do
    case System.cmd("git", ["merge-base", "--is-ancestor", sha, "refs/remotes/origin/" <> branch],
           cd: path,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        {:ok, true}

      {_, 1} ->
        {:ok, false}

      _ ->
        # Missing head objects (for example a deleted squash branch) are not
        # contained. Missing target refs are a read failure, not negative evidence.
        case System.cmd(
               "git",
               ["rev-parse", "--verify", "refs/remotes/origin/#{branch}^{commit}"],
               cd: path,
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            case System.cmd("git", ["cat-file", "-e", sha <> "^{commit}"],
                   cd: path,
                   stderr_to_stdout: true
                 ) do
              {_, 0} -> {:error, :git_failed}
              _ -> {:ok, false}
            end

          _ ->
            {:error, :git_failed}
        end
    end
  rescue
    _ -> {:error, :git_failed}
  end
end
