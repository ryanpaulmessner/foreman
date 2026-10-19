defmodule Foreman.CardText do
  @moduledoc """
  Agent-written card text as safe Markdown (raw HTML omitted, see
  `Foreman.Markdown`), with bare Markdown paths that name an existing file in a
  configured repo turned into document-viewer links.

  Relative paths resolve against the card's repo first, then the other
  configured repos in order. Absolute (and `~/`) paths link only beneath a
  configured repo root. `..` segments never link. Only `.md` files are linked,
  because the viewer renders Markdown only.
  """
  alias Foreman.{Documents, Markdown}

  @max_docs 20
  @max_paths 50

  @doc "Configured repos as `%{\"key\" => key, \"path\" => root}`."
  def repos do
    case Foreman.RuntimeState.config() do
      %{config: %{"repos" => repos}} when is_list(repos) ->
        for %{"key" => key, "path" => path} <- repos,
            is_binary(path),
            do: %{"key" => key, "path" => path}

      _ ->
        []
    end
  end

  def render(text, repo_key, repos \\ nil)
  def render(text, _, _) when not is_binary(text), do: ""

  def render(text, repo_key, repos) do
    repos = repos || repos()

    # Each distinct path is checked once, and only the first @max_paths are.
    links =
      text
      |> Markdown.path_candidates()
      |> Enum.take(@max_paths)
      |> Enum.flat_map(fn path ->
        case resolve(path, repo_key, repos) do
          {repo, relative} -> [{path, Markdown.viewer_path(repo, relative)}]
          nil -> []
        end
      end)
      |> Map.new()

    Markdown.render(text,
      repo: if(Enum.any?(repos, &(&1["key"] == repo_key)), do: repo_key),
      header_ids: false,
      link_paths: &Map.get(links, &1)
    )
  end

  @doc "Whether the text is long enough to show its first lines with Show more."
  def long?(text) when is_binary(text),
    do: String.length(text) > 480 or length(String.split(text, "\n")) > 8

  def long?(_), do: false

  @doc "A detected path as `{repo_key, repo-relative path}` when the file exists."
  def resolve(path, repo_key, repos) do
    path = if String.starts_with?(path, "~/"), do: Path.expand(path), else: path

    cond do
      ".." in Path.split(path) ->
        nil

      Path.type(path) == :absolute ->
        Enum.find_value(repos, fn repo ->
          root = Path.expand(repo["path"])

          if String.starts_with?(path, root <> "/") do
            relative = Path.relative_to(path, root)
            if Documents.document?(root, relative), do: {repo["key"], relative}
          end
        end)

      true ->
        repos
        |> Enum.sort_by(&(&1["key"] != repo_key))
        |> Enum.find_value(fn repo ->
          if Documents.document?(Path.expand(repo["path"]), path), do: {repo["key"], path}
        end)
    end
  end

  @doc """
  Validates `--doc` values for a request on `repo_key`: repo-relative to that
  repo, or absolute beneath (or in a worktree of) a configured repo. Every
  path must name a readable Markdown file.
  """
  def docs(paths, repo_key, repos \\ nil)
  def docs(nil, _, _), do: {:ok, []}

  def docs(paths, repo_key, repos) when is_list(paths) and length(paths) <= @max_docs do
    repos = repos || repos()

    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case doc(path, repo_key, repos) do
        {:ok, doc} -> {:cont, {:ok, acc ++ [doc]}}
        :error -> {:halt, {:error, :invalid_doc}}
      end
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.uniq(docs)}
      error -> error
    end
  end

  def docs(_, _, _), do: {:error, :invalid_doc}

  defp doc(path, repo_key, repos)
       when is_binary(path) and byte_size(path) in 1..4096 do
    path = if String.starts_with?(path, "~/"), do: Path.expand(path), else: path

    candidates =
      if Path.type(path) == :absolute,
        do: Enum.sort_by(repos, &(&1["key"] != repo_key)),
        else: Enum.filter(repos, &(&1["key"] == repo_key))

    Enum.find_value(candidates, :error, fn repo ->
      case Documents.read(repo["path"], path) do
        {:ok, %{path: path}} -> {:ok, %{"repo" => repo["key"], "path" => path}}
        _ -> nil
      end
    end)
  end

  defp doc(_, _, _), do: :error
end
