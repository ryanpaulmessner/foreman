defmodule Foreman.Documents do
  @moduledoc """
  Read-only Markdown access beneath a configured folder. Symlinks are refused,
  including intermediate directories. Reads are bounded to 1 MiB.
  """
  @max_bytes 1_048_576
  def list(root) do
    (["README.md", "AGENTS.md"] ++ walk(root, "docs"))
    |> Enum.filter(&(regular_path(Path.join(root, &1)) == :ok))
    |> Enum.sort()
  end

  defp walk(root, relative) do
    full = Path.join(root, relative)

    case File.lstat(full) do
      {:ok, %{type: :directory}} ->
        case File.ls(full) do
          {:ok, names} -> Enum.flat_map(names, &walk(root, Path.join(relative, &1)))
          _ -> []
        end

      {:ok, %{type: :regular}} ->
        if String.downcase(Path.extname(relative)) == ".md", do: [relative], else: []

      _ ->
        []
    end
  end

  def read(root, path) when is_binary(root) and is_binary(path) do
    root = Path.expand(root)
    {allowed_root, full} = resolve(root, Path.expand(path, root))

    with true <- inside?(full, allowed_root),
         true <- String.downcase(Path.extname(full)) == ".md",
         :ok <- regular_path(full),
         {:ok, content} <- bounded_read(full),
         true <- String.valid?(content) do
      {:ok,
       %{
         content: content,
         path: if(allowed_root == root, do: Path.relative_to(full, root), else: full)
       }}
    else
      false -> {:error, :refused}
      {:error, reason} -> {:error, reason}
    end
  end

  def read(_, _), do: {:error, :refused}

  @doc "Cheap existence check for a Markdown file strictly beneath `root` (no read, no worktree lookup)."
  def document?(root, path) when is_binary(root) and is_binary(path) do
    root = Path.expand(root)
    full = Path.expand(path, root)

    inside?(full, root) and String.downcase(Path.extname(full)) == ".md" and
      regular_path(full) == :ok
  end

  def document?(_, _), do: false

  @doc "Reads a document for display, falling back to a recorded artifact reference."
  def open(%{"key" => key, "path" => root}, path) do
    case read(root, path) do
      {:error, _} = error ->
        if is_binary(path) and Foreman.Overlay.document_reference?(key, path),
          do: read_recorded(root, path),
          else: error

      document ->
        document
    end
  end

  @doc "Fallback for an exact artifact reference already recorded in this project's history. Never reads the old root."
  def read_recorded(root, path) do
    if Path.type(path) == :absolute and ".." not in Path.split(path) do
      list(root)
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.find_value({:error, :refused}, fn relative ->
        suffix = "/" <> relative

        if String.ends_with?(path, suffix) do
          old_root = binary_part(path, 0, byte_size(path) - byte_size(suffix))
          if File.lstat(old_root) == {:error, :enoent}, do: read(root, relative)
        end
      end)
    else
      {:error, :refused}
    end
  end

  # Git retains missing worktree registrations until pruning. Only these trusted
  # roots can supply a relative fallback; an arbitrary outside path cannot.
  defp resolve(root, full) do
    if inside?(full, root) do
      {root, full}
    else
      case System.cmd("git", ["-C", root, "worktree", "list", "--porcelain"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.find_value({root, full}, fn
            "worktree " <> tree ->
              if inside?(full, tree) do
                if File.exists?(tree),
                  do: {tree, full},
                  else: {root, Path.join(root, Path.relative_to(full, tree))}
              end

            _ ->
              nil
          end)

        _ ->
          {root, full}
      end
    end
  end

  defp inside?(path, root), do: String.starts_with?(path, root <> "/")

  defp regular_path(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn part, :ok ->
      case File.lstat(part) do
        {:ok, %{type: :directory}} when part != path -> {:cont, :ok}
        {:ok, %{type: :regular}} when part == path -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :refused}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp bounded_read(path) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, @max_bytes + 1) end) do
      {:ok, data} when is_binary(data) and byte_size(data) <= @max_bytes -> {:ok, data}
      {:ok, :eof} -> {:ok, ""}
      {:ok, data} when is_binary(data) -> {:error, :too_large}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
