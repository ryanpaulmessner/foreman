defmodule Foreman.CodeCheckout do
  @moduledoc """
  Where a project's code lives. Tickets always come from `path`; push and the worktree check
  use `code_path` when set (a separate repo, e.g. a nested checkout with its own remote),
  else `path`. Reads `.git` files directly; never launches git.
  """
  alias Foreman.Requests.LocalRefs

  @doc "The code checkout for a configured repo map."
  def path(repo), do: repo["code_path"] || repo["path"]

  @doc """
  Load-time check for an explicit `code_path`: a git checkout whose `origin` points at the
  repo's `github` remote. Returns `:ok` or an error message.
  """
  def check(%{"code_path" => code_path} = repo) when is_binary(code_path) do
    cond do
      not is_binary(repo["github"]) ->
        {:error, "code_path requires a github remote"}

      not match?({:ok, _, _}, LocalRefs.common_dir(code_path)) ->
        {:error, "code_path is not a git checkout: #{code_path}"}

      origin_slug(code_path) != String.downcase(repo["github"]) ->
        {:error, "code_path origin does not match github #{repo["github"]}"}

      true ->
        :ok
    end
  end

  def check(_), do: :ok

  @doc "`owner/repo` (lowercased) of the checkout's `origin` when it is a GitHub URL, else nil."
  def origin_slug(checkout) do
    with {:ok, _, common} <- LocalRefs.common_dir(checkout),
         {:ok, config} <- File.read(Path.join(common, "config")),
         url when is_binary(url) <- origin_url(config) do
      github_slug(url)
    else
      _ -> nil
    end
  end

  defp origin_url(config) do
    config
    |> String.split("\n")
    |> Enum.reduce_while(false, fn line, in_origin? ->
      line = String.trim(line)

      cond do
        String.starts_with?(line, "[") ->
          {:cont, Regex.match?(~r/\A\[remote\s+"origin"\]\z/i, line)}

        in_origin? ->
          case Regex.run(~r/\Aurl\s*=\s*(.+)\z/i, line) do
            [_, url] -> {:halt, url |> String.trim() |> String.trim("\"")}
            _ -> {:cont, true}
          end

        true ->
          {:cont, false}
      end
    end)
    |> case do
      url when is_binary(url) -> url
      _ -> nil
    end
  end

  defp github_slug(url) do
    case Regex.run(
           ~r{\A(?:https://(?:[^@/]+@)?github\.com/|ssh://git@github\.com(?::22)?/|git@github\.com:)([^/\s]+/[^/\s]+?)(?:\.git)?/?\z}i,
           url
         ) do
      [_, slug] -> String.downcase(slug)
      _ -> nil
    end
  end
end
