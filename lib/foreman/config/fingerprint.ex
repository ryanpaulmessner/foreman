defmodule Foreman.Config.Fingerprint do
  @moduledoc "Read-only reload inputs, including store admission and Git checkout identity."

  def read(directory, discovered, config) do
    repos = if config, do: config["repos"], else: []

    inputs = {
      directory,
      files(directory, ~w(foreman.toml foreman.local.toml)),
      files(Application.app_dir(:foreman, "priv"), ["foreman.defaults.toml"]),
      Enum.map(discovered, &{&1, marker(Path.join(&1, ".beads"))}),
      Enum.map(repos, fn repo ->
        {repo["key"], checkout(repo["path"]), checkout(repo["code_path"])}
      end)
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(inputs)) |> Base.encode16(case: :lower)
  end

  defp checkout(nil), do: nil

  defp checkout(path) do
    {
      path,
      marker(path),
      File.read_link(path),
      marker(Path.join(path, ".beads")),
      files(path, ~w(.beads/metadata.json .beads/config.yaml .beads/redirect)),
      git(path)
    }
  end

  defp git(path) do
    case Foreman.Requests.LocalRefs.common_dir(path) do
      {:ok, identity, common} ->
        {identity, common, files(path, [".git"]),
         files(common, ~w(config config.worktree commondir gitdir))}

      _ ->
        parent = Path.dirname(path)
        if parent == path, do: nil, else: git(parent)
    end
  end

  defp files(root, names) do
    Enum.map(names, fn name ->
      path = Path.join(root, name)
      {name, marker(path), File.read(path)}
    end)
  end

  # Contents supplement mtime/size: same-size edits within one timestamp tick still reload.
  defp marker(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        {stat.type, stat.major_device, stat.inode, stat.size, stat.mtime, stat.mode}

      error ->
        error
    end
  end
end
