defmodule Foreman.ScratchDocs do
  @moduledoc "Scratch repo folders for document tests."

  @doc "A fresh directory outside any git checkout, with no symlinked parents (macOS /var)."
  def dir(name) do
    {tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())
    dir = Path.join(String.trim(tmp), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  @doc "Writes `files` (relative path => content) beneath `root`."
  def write(root, files) do
    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), content)
    end

    root
  end

  @doc "Stores a board config whose repos are `repos` (key => root)."
  def configure(repos) do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    repos = for {key, path} <- repos, do: %{"key" => key, "path" => path, "enabled" => true}

    Foreman.Repo.insert_all(
      "board_config",
      [
        %{
          id: 1,
          config: Map.put(config, "repos", repos),
          source: "test",
          discovered: [],
          loaded_at: DateTime.utc_now()
        }
      ],
      on_conflict: {:replace, [:config]},
      conflict_target: [:id]
    )
  end
end
