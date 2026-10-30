defmodule Foreman.CLITransport do
  @moduledoc "Bounded localhost HTTP, with a direct Postgres fallback. No local data files."

  def deliver(request, opts \\ []) do
    {event, body} = classify(http(request, opts))

    {event, body} =
      if event == :unavailable and
           (request["transient"] == true or request["action"] in ["show", "ls", "wait"]),
         do: {:refused, %{"warning" => "foreman unavailable; read was not queued"}},
         else: {event, body}

    advance(:sending, event, body, request, opts)
  end

  defp classify({:ok, %{status: 200, body: body}}) when is_map(body), do: {:accepted, body}

  defp classify({:ok, %{status: 409, body: %{"stage" => stage, "allowed" => allowed} = body}})
       when is_binary(stage) and is_list(allowed), do: {:conflict, body}

  defp classify({:ok, %{status: status, body: body}}) when status in [400, 404, 422],
    do:
      {:refused,
       Map.merge(
         if(is_map(body), do: Map.take(body, ["stage", "next_command", "missing"]), else: %{}),
         %{"warning" => "foreman refused command: #{error(body)}", "error" => error(body)}
       )}

  defp classify(_), do: {:unavailable, %{}}

  defp advance(state, event, body, request, opts) do
    {next, [effect]} = Foreman.DeliveryMachine.step(state, event, %{})

    case effect do
      {:reply, :conflict} ->
        {3, body}

      {:reply, kind} when kind in [:ok, :warning] ->
        {0, body}

      {:reply, kind} when kind in [:spooled, :lost] ->
        warning =
          if kind == :spooled,
            do: "foreman unavailable; event spooled for replay",
            else: "foreman and spool unavailable; event not saved; agent may continue"

        {0, %{"warning" => warning, "request_id" => request["request_id"]}}

      {:persist, :request} ->
        result = if spool(request, opts) == :ok, do: :saved, else: :failed
        advance(next, result, %{}, request, opts)
    end
  end

  defp http(request, opts) do
    url = Keyword.get(opts, :url, System.get_env("FOREMAN_URL", "http://127.0.0.1:4747"))
    uri = URI.parse(url)

    with true <-
           uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] and
             is_nil(uri.userinfo),
         {:ok, token} <- Foreman.AgentToken.read() do
      Req.post(
        url <> "/api/commands",
        [
          json: request,
          auth: {:bearer, token},
          retry: false,
          redirect: false,
          receive_timeout: 2_000,
          connect_options: [timeout: 1_000],
          pool_timeout: 1_000
        ] ++ Keyword.get(opts, :req_options, [])
      )
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp spool(request, opts) do
    db = Keyword.get(opts, :database, database_options())

    case Postgrex.start_link(
           db ++
             [
               connect_timeout: 1_000,
               timeout: 1_000,
               backoff_type: :stop,
               max_restarts: 0,
               shutdown: 100
             ]
         ) do
      {:ok, pid} ->
        Process.unlink(pid)

        try do
          case Postgrex.query(
                 pid,
                 "INSERT INTO spooled_events (request_id, request) VALUES ($1, $2) ON CONFLICT (request_id) DO NOTHING",
                 [Ecto.UUID.dump!(request["request_id"]), request],
                 timeout: 1_000
               ) do
            {:ok, _} -> :ok
            _ -> :error
          end
        after
          try do
            GenServer.stop(pid, :normal, 100)
          catch
            :exit, _ -> Process.exit(pid, :kill)
          end
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp database_options do
    url =
      Enum.find(
        [System.get_env("FOREMAN_DATABASE_URL"), System.get_env("DATABASE_URL")],
        &(is_binary(&1) and &1 != "")
      )

    case url do
      nil ->
        [
          hostname: System.get_env("PGHOST", "localhost"),
          port: String.to_integer(System.get_env("PGPORT", "5432")),
          username: System.get_env("PGUSER", "postgres"),
          password: System.get_env("PGPASSWORD", "postgres"),
          database: System.get_env("PGDATABASE", "foreman_dev")
        ]

      url ->
        uri = URI.parse(url)
        [user | password] = String.split(uri.userinfo || "postgres", ":", parts: 2)

        [
          hostname: uri.host,
          port: uri.port || 5432,
          username: URI.decode(user),
          password: URI.decode(List.first(password) || ""),
          database: URI.decode(String.trim_leading(uri.path || "", "/"))
        ]
    end
  end

  defp error(%{"error" => reason}) when is_binary(reason), do: reason
  defp error(_), do: "invalid request"
end
