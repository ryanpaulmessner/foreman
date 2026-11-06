defmodule Foreman.DocCheck do
  @moduledoc """
  The commit-time half of `foreman check` (docs/specs/doc-layout.md, decision 5).

  Judges the `.md` and `.html` files added in the commit being made (the git index) with
  `Foreman.DocLayout.classify/2`. Edits and deletes are never checked, so files already in
  a `[docs] legacy` folder stay editable while new ones there are refused. Rules come from
  the repo's `[[repos]]` entry in foreman.toml (`docs = { allow = [...], legacy = [...] }`);
  an unregistered repo or an entry without `docs` has no allow globs and no legacy folders.
  """
  alias Foreman.DocLayout
  alias Foreman.Requests.LocalRefs

  @extensions ~w(.md .html)

  @doc """
  Layout errors and warnings for the staged adds in `root`. With nothing added the result
  is empty and no config is read. If git cannot be read the check is skipped with a
  warning; it never fails a commit on its own. `config_dir:` defaults to
  `FOREMAN_CONFIG_DIR` or `~/.config/foreman`.
  """
  def check(root, opts \\ []) do
    case added_documents(root) do
      {:ok, []} ->
        %{errors: [], warnings: []}

      {:ok, paths} ->
        case rules(root, opts) do
          {:ok, rules} -> %{errors: Enum.flat_map(paths, &error(&1, rules)), warnings: []}
          {:error, reason} -> %{errors: [%{file: "foreman.toml", reason: reason}], warnings: []}
        end

      {:error, reason} ->
        %{errors: [], warnings: ["document layout check skipped: #{reason}"]}
    end
  end

  @doc """
  Repo-relative `.md`/`.html` paths added in the index, sorted. Rename detection is off,
  so a rename shows up as an add at its new path whatever the user's git config says.
  """
  def added_documents(root) do
    args = ~w(diff --cached --name-only -z --no-renames --diff-filter=A --no-ext-diff)

    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok,
         output
         |> String.split(<<0>>, trim: true)
         |> Enum.filter(&(String.downcase(Path.extname(&1)) in @extensions))
         |> Enum.sort()}

      {output, code} ->
        {:error, "git exited #{code}: #{String.trim(output)}"}
    end
  rescue
    error in ErlangError -> {:error, "git unavailable: #{Exception.message(error)}"}
  end

  @doc """
  `allow:`, `legacy:` and `prefixes:` for `DocLayout.classify/2`, from the registered repo
  whose checkout shares `root`'s git directory (so a worktree gets its repo's rules).
  """
  def rules(root, opts \\ []) do
    directory =
      Keyword.get_lazy(opts, :config_dir, fn ->
        System.get_env("FOREMAN_CONFIG_DIR", Path.expand("~/.config/foreman"))
      end)

    with {:ok, config} <- Foreman.Config.load(directory) do
      repo = registered_repo(root, config["repos"])
      docs = (repo && repo["docs"]) || %{}
      prefix = repo && repo["prefix"]

      {:ok,
       allow: Map.get(docs, "allow", []),
       legacy: Map.get(docs, "legacy", []),
       prefixes: Enum.uniq(List.wrap(prefix) ++ ticket_prefixes(root))}
    end
  end

  defp registered_repo(root, repos) do
    case LocalRefs.common_dir(root) do
      {:ok, identity, _} ->
        Enum.find(repos, &match?({:ok, ^identity, _}, LocalRefs.common_dir(&1["path"])))

      _ ->
        nil
    end
  end

  # Ticket file names name the repo's prefix even when the repo is not registered.
  defp ticket_prefixes(root) do
    root
    |> Path.join("tickets/*.md")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".md") |> String.split("-", parts: 2) |> hd()))
  end

  defp error(path, rules) do
    case DocLayout.classify(path, rules) do
      :allowed ->
        []

      {:legacy, folder, command} ->
        reason =
          "#{folder} is a legacy folder: existing files can be edited, new files are refused"

        [%{file: path, reason: reason, command: command}]

      {:refused, reason, command} ->
        [%{file: path, reason: reason, command: command}]
    end
  end
end
