defmodule Foreman.Previews.Devserve do
  @moduledoc "Argv-only devserve boundary. No systemd or database operations live here."
  @callback list() :: {:ok, [map()]} | {:error, String.t()}
  @callback up(String.t(), String.t()) :: :ok | {:error, String.t()}
  @callback down(String.t()) :: :ok | {:error, String.t()}
  @callback logs(String.t()) :: {:ok, String.t()} | {:error, String.t()}

  def list do
    with {:ok, text} <- command(["ls", "--json"], [], 1_048_576),
         {:ok, %{"previews" => rows}} when is_list(rows) <- Jason.decode(text),
         true <- Enum.all?(rows, &valid?/1) do
      {:ok, Enum.map(rows, &localhost_url/1)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "Invalid devserve registry"}
    end
  end

  def up(path, owner) do
    if Path.type(path) == :absolute,
      do: result(command(["up", path], [{~c"FOREMAN_SESSION", String.to_charlist(owner)}])),
      else: {:error, "Invalid worktree"}
  end

  def down(unit) do
    if unit?(unit),
      do: result(command(["down", unit, "--drop-db"])),
      else: {:error, "Invalid preview unit"}
  end

  def logs(unit) do
    if unit?(unit), do: command(["logs", unit]), else: {:error, "Invalid preview unit"}
  end

  defp result({:ok, _}), do: :ok
  defp result(error), do: error

  defp unit?(unit),
    do: is_binary(unit) and Regex.match?(~r/\Adevserve-[a-zA-Z0-9_.-]+\.service\z/, unit)

  defp valid?(row) when is_map(row) do
    unit?(row["unit"]) and is_binary(row["worktree"]) and Path.type(row["worktree"]) == :absolute and
      row["state"] in ~w(starting running failed stopped) and is_boolean(row["missing"]) and
      safe_url?(row["url"])
  end

  defp valid?(_), do: false

  defp safe_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost"] and is_integer(uri.port) and
      uri.port in 1024..65535 and is_nil(uri.userinfo)
  end

  defp safe_url?(_), do: false

  # Links say localhost: Microsoft sign-in accepts a localhost return address on
  # any port, but not 127.0.0.1, so a preview's SSO works without registering it.
  defp localhost_url(%{"url" => url} = row) do
    %{row | "url" => url |> URI.parse() |> Map.put(:host, "localhost") |> URI.to_string()}
  end

  defp command(args, env \\ [], limit \\ 16_384) do
    with executable when is_binary(executable) <- System.find_executable("devserve"),
         timeout when is_binary(timeout) <- System.find_executable("timeout") do
      port =
        Port.open({:spawn_executable, timeout}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["--signal=TERM", "--kill-after=5", "180", executable | args],
          env: env
        ])

      collect(port, "", limit)
    else
      _ -> {:error, "devserve or timeout is unavailable"}
    end
  rescue
    _ -> {:error, "Unable to execute devserve"}
  end

  defp collect(port, output, limit) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        output =
          if byte_size(output) > limit,
            do: binary_part(output, byte_size(output) - limit, limit),
            else: output

        collect(port, output, limit)

      {^port, {:exit_status, 0}} ->
        {:ok, String.replace_invalid(output)}

      {^port, {:exit_status, status}} ->
        {:error, "devserve exited #{status}; inspect preview logs"}
    end
  end
end
