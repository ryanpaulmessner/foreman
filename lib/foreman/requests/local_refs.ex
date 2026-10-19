defmodule Foreman.Requests.LocalRefs do
  @moduledoc "Read-only files-backend Git identity and branch reads; never launches git. Unknown layouts fail closed."

  def common_dir(path) when is_binary(path) do
    dot = Path.join(path, ".git")

    with {:ok, gitdir} <- git_dir(dot),
         common <- common(gitdir),
         {:ok, %{type: :directory} = stat} <- File.stat(common) do
      {:ok, {stat.major_device, stat.inode}, common}
    else
      _ -> {:error, :foreign_worktree}
    end
  end

  def common_dir(_), do: {:error, :foreign_worktree}

  def same_repo(path, configured) do
    with {:ok, identity, _} <- common_dir(configured),
         {:ok, ^identity, _} <- common_dir(path) do
      :ok
    else
      _ -> {:error, :foreign_worktree}
    end
  end

  # `core.hookspath` is neutralised by the push job's `-c core.hooksPath=/dev/null` (command
  # line wins) and `--no-verify`; `push.default` is inert because the job always pushes an
  # explicit refspec. Both appear in real checkouts (ReportSystem sets them).
  @config_keys %{
    "core" =>
      ~w(repositoryformatversion filemode bare logallrefupdates symlinks ignorecase precomposeunicode worktree hookspath),
    "remote" => ~w(url fetch pushurl),
    "branch" => ~w(remote merge rebase pushremote description),
    "user" => ~w(name email signingkey),
    "push" => ~w(default)
  }

  @doc "Reject executable/includes/URL rewrites and unknown storage extensions before invoking git."
  def safe_config(path) do
    with {:ok, _, common} <- common_dir(path),
         {:ok, config} <- File.read(Path.join(common, "config")),
         false <- File.exists?(Path.join(common, "config.worktree")),
         {:ok, _} <- Enum.reduce_while(String.split(config, "\n"), {:ok, nil}, &config_line/2) do
      :ok
    else
      _ -> {:error, :unsafe_git_config}
    end
  end

  defp config_line(line, {:ok, section}) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, ["#", ";"]) ->
        {:cont, {:ok, section}}

      String.ends_with?(line, "\\") ->
        {:halt, :error}

      String.starts_with?(line, "[") ->
        case Regex.run(~r/\A\[(core|remote|branch|user|push)(?: "[^"\\]+")?\]\z/i, line) do
          [_, next] -> {:cont, {:ok, String.downcase(next)}}
          _ -> {:halt, :error}
        end

      true ->
        key = line |> String.split("=", parts: 2) |> hd() |> String.trim() |> String.downcase()

        if key in Map.get(@config_keys, section, []),
          do: {:cont, {:ok, section}},
          else: {:halt, :error}
    end
  end

  def branch(path, name) do
    with true <- branch_name?(name),
         {:ok, _, common} <- common_dir(path) do
      ref = "refs/heads/" <> name

      case File.read(Path.join(common, ref)) do
        {:ok, sha} -> sha(String.trim(sha))
        {:error, :enoent} -> packed(common, ref)
        _ -> {:error, :local_sha_unknown}
      end
    else
      _ -> {:error, :local_sha_unknown}
    end
  end

  def branch_name?(name) when is_binary(name) do
    name != "" and byte_size(name) <= 255 and
      Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9_.\/-]*\z/, name) and
      not String.contains?(name, ["..", "//", "@{"]) and
      Enum.all?(
        String.split(name, "/"),
        &(not String.starts_with?(&1, ".") and not String.ends_with?(&1, [".", ".lock"]) and
            &1 != "")
      )
  end

  def branch_name?(_), do: false

  def sha(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, value),
      do: {:ok, value},
      else: {:error, :local_sha_unknown}
  end

  def sha(_), do: {:error, :local_sha_unknown}

  defp git_dir(dot) do
    if File.dir?(dot) do
      {:ok, dot}
    else
      case File.read(dot) do
        {:ok, "gitdir: " <> relative} ->
          {:ok, Path.expand(String.trim(relative), Path.dirname(dot))}

        _ ->
          {:error, :foreign_worktree}
      end
    end
  end

  defp common(gitdir) do
    case File.read(Path.join(gitdir, "commondir")) do
      {:ok, relative} -> Path.expand(String.trim(relative), gitdir)
      _ -> gitdir
    end
  end

  defp packed(common, ref) do
    case File.read(Path.join(common, "packed-refs")) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, " ", parts: 2) do
            [sha, ^ref] -> sha(sha)
            _ -> nil
          end
        end) || {:error, :local_sha_unknown}

      _ ->
        {:error, :local_sha_unknown}
    end
  end
end
