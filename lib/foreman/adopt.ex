defmodule Foreman.Adopt do
  @moduledoc "Explicit, local repository onboarding. Never commits."
  alias Foreman.{AdoptConfig, AdoptMachine, BeadsConversion, TicketStore}

  @agent_block "<!-- BEGIN FOREMAN -->\n## Tickets\n\nUse the globally linked `foreman` skill (`~/.agents/skills/foreman/SKILL.md`).\nDocuments: follow the `foreman` skill's Documents section before writing a document.\n<!-- END FOREMAN -->\n"
  @hook_block "# BEGIN FOREMAN CHECK\nforeman check || exit $?\n# END FOREMAN CHECK\n"

  def run(root, opts \\ []) do
    root = Path.expand(root)

    config =
      Keyword.get(opts, :config_dir) || System.get_env("FOREMAN_CONFIG_DIR") ||
        Path.expand("~/.config/foreman")

    with :ok <- checkout(root),
         :ok <- safe_paths(root),
         {:ok, hooks} <- hooks(root),
         {:ok, records} <- export(root),
         {:ok, inferred} <- entry(root, records),
         {:ok, entry} <- registered_identity(config, inferred, records),
         {:ok, _} <- AdoptConfig.plan(config, entry),
         {:ok, agents} <- agents(root),
         {:ok, tickets} <- BeadsConversion.convert(records),
         [] <- TicketStore.validate_graph(tickets) do
      lock = Path.join(root, ".git/foreman-adopt-lock")

      case File.mkdir(lock) do
        :ok ->
          try do
            execute(root, config, entry, records, tickets, agents, hooks)
          after
            File.rmdir!(lock)
          end

        {:error, reason} ->
          {:error, "adopt lock: #{inspect(reason)}"}
      end
    else
      errors when is_list(errors) -> {:error, inspect(errors)}
      error -> error
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute(root, config, entry, records, tickets, agents, hooks) do
    beads? = File.dir?(Path.join(root, ".beads"))
    source_snapshot = if beads?, do: snapshot!(Path.join(root, ".beads")), else: nil
    backup = if beads?, do: backup!(root, config), else: nil

    if beads? and snapshot!(Path.join(root, ".beads")) != source_snapshot,
      do: raise("beads changed during backup; preserved .beads")

    export_path = if backup, do: backup <> ".export.jsonl", else: nil

    if export_path,
      do:
        File.write!(export_path, Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n")), [
          :exclusive
        ])

    state = advance(:prepared, :backup)
    {:ok, existing} = TicketStore.load(root)
    # Existing tickets may only be identical; never replace a user's work on retry.
    if beads? and
         Enum.any?(existing, fn {id, ticket} ->
           Map.take(ticket, [:facts, :body]) != tickets[id]
         end),
       do: raise("existing tickets differ; reconcile before adopting")

    desired = if beads?, do: tickets, else: existing
    :ok = TicketStore.save(root, existing, desired)

    changes =
      if beads?,
        do: Enum.map(Map.keys(tickets) -- Map.keys(existing), &"tickets/#{&1}.md"),
        else: []

    changes = if File.dir?(Path.join(root, "tickets")), do: changes, else: ["tickets/" | changes]
    File.mkdir_p!(Path.join(root, "tickets"))
    state = advance(state, :publish)
    [] = TicketStore.check(root)
    {:ok, loaded} = TicketStore.load(root)

    comparison =
      if beads? do
        {:ok, fresh} = export(root)
        # Export must not change underneath the migration, including ignored metadata.
        if fresh != records, do: raise("beads changed during adoption; preserved .beads")
        {:ok, comparison} = BeadsConversion.compare(fresh, loaded)
        comparison
      end

    state = advance(state, :verify)
    # Hook and agent text was validated before any publication.
    changes = put_file(root, "AGENTS.md", agents, changes)

    changes =
      Enum.reduce(hooks, changes, fn {name, text}, acc ->
        path = ".foreman/hooks/#{name}"
        mode = hook_mode(root, name)
        changed = put_file(root, path, text, acc)
        full_path = Path.join(root, path)

        if Bitwise.band(File.stat!(full_path).mode, 0o777) != mode do
          File.chmod!(full_path, mode)
          Enum.uniq([path | changed])
        else
          changed
        end
      end)

    changes = clean_old_hooks(root, changes)
    hook_path = git(root, ["config", "--local", "--get", "core.hooksPath"], true)

    changes =
      if hook_path == ".foreman/hooks",
        do: changes,
        else: ["git config core.hooksPath=.foreman/hooks" | changes]

    if hook_path != ".foreman/hooks",
      do: git(root, ["config", "--local", "core.hooksPath", ".foreman/hooks"])

    if beads? do
      if snapshot!(Path.join(root, ".beads")) != source_snapshot,
        do: raise("beads changed during adoption; preserved .beads")

      File.rm_rf!(Path.join(root, ".beads"))
    end

    changes = if beads?, do: ["remove .beads (backup: #{backup})" | changes], else: changes
    state = advance(state, :retire)
    {:ok, appended} = AdoptConfig.append(config, entry)
    changes = if appended == "", do: changes, else: ["append foreman.toml" | changes]
    :finished = advance(state, :finish)

    {:ok,
     %{
       changes: Enum.sort(changes),
       backup: backup,
       export: export_path,
       comparison: comparison,
       config_entry: appended,
       entry: entry
     }}
  end

  defp advance(state, event) do
    {next, _effects} = AdoptMachine.step(state, event, %{})
    next
  end

  defp checkout(root) do
    if File.dir?(Path.join(root, ".git")) and git(root, ["rev-parse", "--show-toplevel"]) == root,
      do: :ok,
      else: {:error, "adopt requires a main checkout, not a linked worktree or subdirectory"}
  end

  defp safe_paths(root) do
    Enum.reduce_while(
      ~w(.git .git/hooks .git/config .beads .foreman .foreman/hooks tickets AGENTS.md),
      :ok,
      fn path, :ok ->
        case File.lstat(Path.join(root, path)) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, "refusing symlink: #{path}"}}
          _ -> {:cont, :ok}
        end
      end
    )
  end

  defp export(root) do
    beads = Path.join(root, ".beads")

    if File.exists?(Path.join(beads, "redirect")),
      do: raise("redirected beads stores must be adopted at their owning checkout")

    if File.dir?(beads), do: snapshot!(beads)
    metadata_path = Path.join(beads, "metadata.json")

    metadata =
      if File.regular?(metadata_path), do: Jason.decode!(File.read!(metadata_path)), else: %{}

    if Map.get(metadata, "dolt_mode", "embedded") != "embedded",
      do: raise("only local embedded beads stores can be adopted")

    cond do
      not File.dir?(beads) ->
        {:ok, []}

      File.dir?(Path.join(beads, "dolt")) or Path.wildcard(Path.join(beads, "*.db")) != [] ->
        # bd is invoked only on an isolated copy; it cannot mutate the source store.
        scratch =
          Path.join(System.tmp_dir!(), "foreman-export-#{System.unique_integer([:positive])}")

        File.mkdir_p!(scratch)

        try do
          File.cp_r!(beads, Path.join(scratch, ".beads"))

          {text, code} =
            System.cmd("bd", ["--readonly", "--sandbox", "-C", scratch, "export", "--all"],
              env: isolated_beads_env(scratch)
            )

          if code == 0,
            do: {:ok, BeadsConversion.decode(text)},
            else: {:error, "bd export failed (#{code}); .beads preserved"}
        after
          File.rm_rf!(scratch)
        end

      File.regular?(Path.join(beads, "issues.jsonl")) ->
        {:ok, beads |> Path.join("issues.jsonl") |> File.read!() |> BeadsConversion.decode()}

      true ->
        {:error, ".beads has no export or supported local database"}
    end
  end

  defp isolated_beads_env(scratch) do
    cleared =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, ["BEADS_", "BD_", "DOLT_", "GIT_"]))
      |> Enum.map(&{&1, nil})

    cleared ++
      [
        {"BD_NO_TELEMETRY", "1"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_TERMINAL_PROMPT", "0"},
        {"DOLT_METRICS_DISABLED", "1"},
        {"BD_METRICS_DISABLED", "true"},
        {"BD_NO_HOOKS", "true"},
        {"BD_DOLT_AUTO_PUSH", "false"},
        {"BD_BACKUP_ENABLED", "false"},
        {"BD_ROUTING_DEFAULT", scratch},
        {"BD_ROUTING_MAINTAINER", scratch},
        {"BD_ROUTING_CONTRIBUTOR", scratch}
      ]
  end

  defp registered_identity(config, inferred, records) do
    with {:ok, current} <- Foreman.Config.load(config) do
      case Enum.find(current["repos"], &(&1["path"] == inferred["path"])) do
        nil ->
          {:ok, inferred}

        repo ->
          empty? =
            records == [] and Path.wildcard(Path.join(inferred["path"], "tickets/*.md")) == []

          prefix = if empty?, do: repo["prefix"] || inferred["prefix"], else: inferred["prefix"]
          {:ok, inferred |> Map.put("key", repo["key"]) |> Map.put("prefix", prefix)}
      end
    end
  end

  defp entry(root, records) do
    key = Path.basename(root) |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "-")
    prefixes = Enum.map(records, &(String.split(&1["id"], "-") |> hd())) |> Enum.uniq()

    prefix =
      case prefixes do
        [] -> key
        [prefix] -> prefix
        _ -> raise "multiple ticket prefixes; explicit reconciliation required"
      end

    origin = git(root, ["remote", "get-url", "origin"], true)

    github =
      case Regex.run(
             ~r/\A(?:git@github\.com:|https:\/\/github\.com\/|ssh:\/\/git@github\.com\/)([^\/]+\/[^\/]+?)(?:\.git)?\z/,
             origin
           ) do
        [_, slug] -> slug
        _ -> nil
      end

    # After migration, use the files' prefix, not a newly guessed basename.
    prefix =
      if records == [] do
        case TicketStore.load(root) do
          {:ok, files} when map_size(files) > 0 ->
            files |> Map.keys() |> hd() |> String.split("-") |> hd()

          _ ->
            prefix
        end
      else
        prefix
      end

    {:ok,
     %{"key" => key, "path" => root, "prefix" => prefix, "tickets" => "files"}
     |> then(fn e -> if github, do: Map.put(e, "github", github), else: e end)}
  end

  defp snapshot!(directory) do
    directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn name ->
      path = Path.join(directory, name)

      case File.lstat!(path).type do
        :directory -> {name, snapshot!(path)}
        :regular -> {name, :crypto.hash(:sha256, File.read!(path))}
        _ -> raise "refusing non-regular beads data: #{path}"
      end
    end)
  end

  defp backup!(root, config) do
    directory = Path.join(config, "backups") |> Path.expand()

    if directory == root or String.starts_with?(directory, root <> "/"),
      do: raise("backup directory must be outside repo")

    File.mkdir_p!(directory)

    path =
      Path.join(directory, "#{Path.basename(root)}-#{System.system_time(:microsecond)}.tar.gz")

    {_, 0} = System.cmd("tar", ["-czf", path, "-C", root, ".beads"])
    {_, 0} = System.cmd("tar", ["-tzf", path])
    path
  end

  defp agents(root) do
    path = Path.join(root, "AGENTS.md")
    text = if File.exists?(path), do: File.read!(path), else: ""
    text = strip_beads(text)

    if String.contains?(text, "<!-- BEGIN FOREMAN -->") do
      if String.contains?(text, @agent_block),
        do: {:ok, text},
        else: {:error, "modified foreman block; reconcile AGENTS.md"}
    else
      {:ok,
       text <>
         if(text == "" or String.ends_with?(text, "\n"), do: "", else: "\n") <>
         "\n" <> @agent_block}
    end
  end

  defp hooks(root) do
    configured = git(root, ["config", "--get", "core.hooksPath"], true)

    directory =
      if configured == "", do: Path.join(root, ".git/hooks"), else: Path.expand(configured, root)

    unless String.starts_with?(directory, root <> "/"),
      do: raise("external hooksPath; refusing to replace it")

    directory
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce(root, fn component, parent ->
      path = Path.join(parent, component)

      if match?({:ok, %{type: :symlink}}, File.lstat(path)),
        do: raise("symlinked hooksPath; refusing to replace it")

      path
    end)

    files = if File.dir?(directory), do: File.ls!(directory), else: []

    hooks =
      files
      |> Enum.reject(&String.ends_with?(&1, ".sample"))
      |> Map.new(fn name ->
        path = Path.join(directory, name)
        {:ok, %{type: :regular}} = File.lstat(path)
        text = strip_beads(File.read!(path))

        if Regex.match?(~r/\bbd\b|\.beads/, text),
          do: raise("unrecognized beads hook in #{name}; reconcile manually")

        {name, text}
      end)

    hooks =
      case File.stat(Path.join(directory, "pre-commit")) do
        {:ok, stat} ->
          if Bitwise.band(stat.mode, 0o111) == 0 and
               not String.contains?(hooks["pre-commit"], @hook_block) do
            if Map.has_key?(hooks, "pre-commit.disabled"),
              do: raise("pre-commit.disabled already exists; reconcile hooks")

            hooks
            |> Map.put("pre-commit.disabled", hooks["pre-commit"])
            |> Map.delete("pre-commit")
          else
            hooks
          end

        _ ->
          hooks
      end

    pre = Map.get(hooks, "pre-commit", "#!/bin/sh\n")
    [first | rest] = String.split(pre, "\n")

    cond do
      not Map.has_key?(hooks, "pre-commit") and Map.has_key?(hooks, "pre-commit.user") ->
        {:ok, Map.put(hooks, "pre-commit", hook_wrapper())}

      String.contains?(pre, @hook_block) ->
        {:ok, hooks}

      String.starts_with?(first, "#!") and
          not Regex.match?(~r/(?:\/|\s)(?:ba|da|z|k)?sh(?:\s|$)/, first) ->
        if Map.has_key?(hooks, "pre-commit.user"),
          do: raise("pre-commit.user already exists; reconcile hooks")

        {:ok, hooks |> Map.put("pre-commit.user", pre) |> Map.put("pre-commit", hook_wrapper())}

      true ->
        pre =
          if String.starts_with?(first, "#!"),
            do: first <> "\n" <> @hook_block <> Enum.join(rest, "\n"),
            else: "#!/bin/sh\n" <> @hook_block <> pre

        {:ok, Map.put(hooks, "pre-commit", pre)}
    end
  end

  defp hook_mode(_root, "pre-commit"), do: 0o755
  defp hook_mode(_root, "pre-commit.disabled"), do: 0o644

  defp hook_mode(root, name) do
    configured = git(root, ["config", "--get", "core.hooksPath"], true)

    directory =
      if configured == "", do: Path.join(root, ".git/hooks"), else: Path.expand(configured, root)

    case File.stat(Path.join(directory, name)) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o777)
      _ -> 0o755
    end
  end

  defp hook_wrapper do
    "#!/bin/sh\n" <>
      @hook_block <>
      "exec \"$(git rev-parse --show-toplevel)/.foreman/hooks/pre-commit.user\" \"$@\"\n"
  end

  defp clean_old_hooks(root, changes) do
    configured = git(root, ["config", "--get", "core.hooksPath"], true)
    directory = Path.expand(configured, root)

    directories =
      [Path.join(root, ".git/hooks") | if(configured == "", do: [], else: [directory])]
      |> Enum.uniq()
      |> Enum.reject(
        &(&1 == Path.join(root, ".foreman/hooks") or
            String.starts_with?(&1, Path.join(root, ".beads") <> "/"))
      )

    Enum.reduce(directories, changes, &clean_hook_directory(root, &1, &2))
  end

  defp clean_hook_directory(root, directory, changes) do
    files = if File.dir?(directory), do: File.ls!(directory), else: []

    Enum.reduce(files, changes, fn name, acc ->
      if String.ends_with?(name, ".sample") do
        acc
      else
        path = Path.join(directory, name)
        {:ok, %{type: :regular}} = File.lstat(path)
        text = File.read!(path)
        cleaned = strip_beads(text)

        if text == cleaned,
          do: acc,
          else: put_file(root, Path.relative_to(path, root), cleaned, acc)
      end
    end)
  end

  defp strip_beads(text) do
    text
    |> String.replace(
      ~r/<!--\s*(?:BEGIN|START) (?:BEADS|bd)[^>]*-->.*?<!--\s*END (?:BEADS|bd)[^>]*-->\n?/si,
      ""
    )
    |> String.replace(
      ~r/^# --- BEGIN (BEADS INTEGRATION[^\n]*|HOUSE BEADS EXPORT) ---\n.*?^# --- END \1 ---\n?/ms,
      ""
    )
  end

  defp put_file(root, relative, text, changes) do
    path = Path.join(root, relative)

    case File.read(path) do
      {:ok, ^text} ->
        changes

      _ ->
        if match?({:ok, %{type: :symlink}}, File.lstat(path)),
          do: raise("refusing symlink #{relative}")

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, text)
        [relative | changes]
    end
  end

  defp git(root, args, optional \\ false) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {text, 0} -> String.trim(text)
      {_, _} when optional -> ""
      {text, code} -> raise "git failed (#{code}): #{text}"
    end
  end
end
