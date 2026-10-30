defmodule Foreman.CLI do
  @moduledoc "Agent escript: offline ticket files plus best-effort server-backed overlay commands."
  @ticket %{
    "dispatch" => "dispatch",
    "progress" => "progress",
    "report" => "report",
    "review" => "review",
    "changes" => "request_changes",
    "commit" => "commit",
    "abandon" => "abandon",
    "revive" => "revive"
  }
  @epic %{
    "create" => "create",
    "spec" => "start_spec",
    "approve" => "approve_spec",
    "ticket" => "ticket",
    "abandon" => "abandon",
    "revive" => "revive"
  }
  @switches [
    name: :string,
    pane: :string,
    reason: :string,
    provider: :string,
    reset_at: :string,
    head: :string,
    body_file: :string,
    pr: :integer,
    worktree: :string,
    remote_branch: :string,
    question: :string,
    option: :keep,
    option_detail: :keep,
    recommendation: :string,
    text: :string,
    doc: :keep,
    timeout: :integer,
    json: :boolean,
    actor: :string,
    session: :string,
    project: :string,
    repo: :string,
    window: :string,
    harness: :string,
    model: :string,
    workdir: :string,
    branch: :string,
    base: :string,
    brief: :string,
    report: :string,
    path: :string,
    sha: :string,
    title: :string,
    spec: :string,
    design: :string,
    beads_epic_id: :string,
    epic: :string,
    epic_project: :string,
    stage: :string
  ]

  def main(args) do
    # Postgres connection supervisors may exit asynchronously. They must not
    # propagate a linked exit into the agent-facing escript.
    Process.flag(:trap_exit, true)
    # Do not boot Foreman.Application: an agent must not become a web/worker node.
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:postgrex)
    Logger.configure(level: :emergency)
    System.halt(run(args))
  end

  def run(args, opts \\ []) do
    cond do
      List.first(args) == "coordinator" -> Foreman.CoordinatorCLI.run(tl(args), opts)
      List.first(args) == "session-hook" -> session_hook(tl(args), opts)
      List.first(args) == "adopt" -> Foreman.AdoptCLI.run(tl(args), opts)
      Foreman.TicketCLI.command?(args, opts) -> Foreman.TicketCLI.run(args, opts)
      true -> run_overlay(List.delete(args, "--overlay"), opts)
    end
  rescue
    _ -> warn(args, "foreman unavailable; agent may continue")
  catch
    :exit, _ -> warn(args, "foreman unavailable; agent may continue")
  end

  defp session_hook([event, id | args], opts) do
    input = Keyword.get_lazy(opts, :hook_input, fn -> IO.read(:stdio, :eof) end)

    with {:ok, input} <- Jason.decode(input),
         {:ok, %{request: request}} <- parse(["ask", "session_waiting", id | args]) do
      request =
        request |> Map.put("request_id", Ecto.UUID.generate()) |> Map.put("transient", true)

      case Foreman.SessionHooks.facts(event, input) do
        {:waiting, facts} ->
          Foreman.CLITransport.deliver(Map.put(request, "facts", facts), opts)

        {:resumed, tool} ->
          Foreman.CLITransport.deliver(
            request |> Map.put("action", "session_resumed") |> Map.put("resume_tool", tool),
            opts
          )

        :activity ->
          Foreman.CLITransport.deliver(Map.put(request, "action", "session_activity"), opts)

        :ignore ->
          :ok
      end
    end

    0
  end

  defp session_hook(_, _), do: 0

  defp run_overlay(args, opts) do
    case parse(args) do
      {:ok, %{request: request, json: json?}} ->
        request = Map.put(request, "request_id", Ecto.UUID.generate())

        {code, body} =
          if request["action"] == "wait" do
            deadline = System.monotonic_time(:millisecond) + request["timeout"] * 1_000
            wait(request, opts, deadline)
          else
            Foreman.CLITransport.deliver(request, opts)
          end

        cond do
          request["action"] == "wait" or json? -> IO.puts(Jason.encode!(body))
          request["action"] == "ask" and is_binary(body["id"]) -> IO.puts(body["id"])
          true -> IO.puts(format(body))
        end

        if request["action"] in ["ask", "wait"], do: 0, else: code

      {:error, message} when is_binary(message) ->
        warn(args, message)

      {:error, _} ->
        warn(args, "usage: foreman <verb> <id> [options]; see docs/sessions/bb-cli.md")
    end
  rescue
    _ -> warn(args, "foreman unavailable; agent may continue")
  catch
    :exit, _ -> warn(args, "foreman unavailable; agent may continue")
  end

  defp wait(request, opts, deadline) do
    {_, body} = Foreman.CLITransport.deliver(request, opts)

    case Foreman.RequestWait.step(:waiting, {:response, body}, %{}) do
      {:finished, _} ->
        {0, body}

      {:waiting, _} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:finished, _} = Foreman.RequestWait.step(:waiting, :timeout, %{})
          {0, body}
        else
          receive do
          after
            min(remaining, Keyword.get(opts, :poll_interval, 500)) ->
              wait(request, opts, deadline)
          end
        end
    end
  end

  defp warn(args, message) do
    if "--json" in args or List.first(args) == "wait",
      do: IO.puts(Jason.encode!(%{warning: message})),
      else: IO.puts("warning: " <> message)

    0
  end

  defp format(%{"id" => id, "url" => url}),
    do:
      id <>
        " " <>
        String.trim_trailing(System.get_env("FOREMAN_URL", "http://127.0.0.1:4747"), "/") <> url

  defp format(%{"warning" => warning}), do: "warning: " <> warning

  defp format(%{"stage" => stage, "allowed" => allowed}),
    do: "stage: #{stage}; allowed: #{Enum.join(allowed, ", ")}"

  defp format(%{"stage" => stage}), do: "stage: #{stage}"
  defp format(body), do: Jason.encode!(body)

  defp request_identity(opts, defaults) do
    %{
      "actor" => opts[:actor] || defaults[:actor] || System.get_env("FOREMAN_ACTOR", "user"),
      "session" => opts[:session] || defaults[:session] || System.get_env("FOREMAN_SESSION"),
      "project" => opts[:project] || opts[:repo],
      "cwd" => defaults[:cwd] || File.cwd!()
    }
  end

  defp ask_facts("session_waiting", opts, _cwd),
    do: %{
      "reason" => opts[:reason],
      "window" => opts[:window],
      "provider" => opts[:provider],
      "reset_at" => opts[:reset_at]
    }

  defp ask_facts("open_pr", opts, _cwd) do
    %{
      "head_branch" => opts[:head],
      "expected_sha" => opts[:sha],
      "base_branch" => opts[:base],
      "title" => opts[:title],
      "body" => File.read!(opts[:body_file])
    }
  end

  defp ask_facts("merge", opts, _cwd), do: %{"number" => opts[:pr], "expected_sha" => opts[:sha]}

  defp ask_facts("push", opts, _cwd) do
    %{
      "worktree" => opts[:worktree],
      "local_branch" => opts[:branch],
      "expected_sha" => opts[:sha],
      "remote_branch" => opts[:remote_branch]
    }
  end

  # Any other kind is sent with decision facts (the server refuses unknown kinds).
  defp ask_facts(_, opts, cwd) do
    facts = %{
      "question" => opts[:question],
      "options" => Keyword.get_values(opts, :option),
      "recommendation" => opts[:recommendation],
      "text" => opts[:text]
    }

    facts =
      case Keyword.get_values(opts, :option_detail) do
        [] ->
          facts

        details ->
          parsed =
            Map.new(details, fn detail ->
              [option, text] = String.split(detail, "=", parts: 2)
              {option, text}
            end)

          Map.put(facts, "option_details", parsed)
      end

    # The board resolves a relative --doc against the ticket's repo, so a file
    # that exists relative to the asker's worktree is sent as its absolute path.
    case Keyword.get_values(opts, :doc) do
      [] ->
        facts

      docs ->
        Map.put(
          facts,
          "docs",
          Enum.map(docs, fn doc ->
            full = Path.expand(doc, cwd)
            if Path.type(doc) == :relative and File.regular?(full), do: full, else: doc
          end)
        )
    end
  end

  defp card_body(opts) do
    if opts[:body_file] do
      with {:ok, %{size: size}} when size <= 20_000 <- File.stat(opts[:body_file]),
           do: File.read(opts[:body_file])
    else
      {:ok, opts[:text]}
    end
  end

  def parse(args, defaults \\ [])
  def parse(["answer" | args], defaults), do: Foreman.AnswerCLI.parse(args, defaults)

  def parse(args, defaults) do
    {opts, args, invalid} = OptionParser.parse(args, strict: @switches)

    invalid =
      if Enum.all?(Keyword.get_values(opts, :option_detail), &String.contains?(&1, "=")),
        do: invalid,
        else: [option_detail: :invalid]

    {kind, args} =
      case args do
        ["epic" | rest] -> {"epic", rest}
        rest -> {"ticket", rest}
      end

    session = opts[:session]

    case {invalid, args} do
      {[], ["session", "register"]} ->
        request =
          Map.new(Keyword.take(opts, [:name, :pane, :workdir, :harness]), fn {k, v} ->
            {to_string(k), v}
          end)

        if Foreman.SessionRegistry.valid?(request) do
          {:ok,
           %{
             request: Map.merge(request, %{"action" => "session_register", "transient" => true}),
             json: opts[:json] || false
           }}
        else
          {:error,
           "session register requires --name <name> --pane <%id> --workdir <absolute-path> --harness claude|pi"}
        end

      {[], ["ask", request_kind, id]} when kind == "ticket" ->
        request =
          request_identity(opts, defaults)
          |> Map.merge(%{
            "action" => "ask",
            "kind" => "ticket",
            "id" => id,
            "request_kind" => request_kind,
            "facts" => ask_facts(request_kind, opts, defaults[:cwd] || File.cwd!())
          })
          # A waiting ask replayed after an outage would outlive the session's resume
          # (clears are never spooled), so it is not queued either.
          |> Map.put("transient", request_kind == "session_waiting")

        {:ok, %{request: request, json: opts[:json] || false}}

      {[], ["card-reply", id]} when kind == "ticket" ->
        with true <- is_binary(opts[:text]) != is_binary(opts[:body_file]),
             {:ok, body} <- card_body(opts),
             true <-
               is_binary(body) and String.valid?(body) and byte_size(body) <= 20_000 and
                 String.trim(body) != "" and not String.contains?(body, <<0>>),
             {:ok, _} <- Ecto.UUID.cast(id) do
          request =
            request_identity(opts, defaults)
            |> Map.merge(%{"action" => "card_reply", "id" => id, "body" => body})

          {:ok, %{request: request, json: opts[:json] || false}}
        else
          _ ->
            {:error,
             "usage: foreman card-reply <request-id> (--text <text> | --body-file <markdown>)"}
        end

      {[], ["withdraw", id]} when kind == "ticket" ->
        if Foreman.Requests.Decision.text?(opts[:reason]) do
          request =
            request_identity(opts, defaults)
            |> Map.merge(%{"action" => "withdraw", "id" => id, "reason" => opts[:reason]})

          {:ok, %{request: request, json: opts[:json] || false}}
        else
          {:error, :usage}
        end

      {[], ["wait", id]} when kind == "ticket" ->
        timeout = Keyword.get(opts, :timeout, 300)

        if timeout >= 0 do
          {:ok, %{request: %{"action" => "wait", "id" => id, "timeout" => timeout}, json: true}}
        else
          {:error, :usage}
        end

      {[], ["dispatch" | _]} when not is_binary(session) or session == "" ->
        {:error, "dispatch requires --session <build-name>"}

      {[], [verb | rest]} ->
        event = if(kind == "epic", do: @epic, else: @ticket)[verb]
        read_or_link = kind == "ticket" and verb in ~w(show ls attach detach)

        valid_args =
          (verb == "ls" and rest == []) or length(rest) == 1 or
            (verb in ~w(progress changes) and length(rest) == 2)

        if (event || read_or_link) && valid_args do
          id = List.first(rest)

          id =
            if kind == "epic" and verb == "create" and not String.starts_with?(id, "draft:"),
              do: "draft:" <> id,
              else: id

          payload =
            Map.new(
              Keyword.take(opts, [
                :window,
                :harness,
                :model,
                :workdir,
                :branch,
                :base,
                :brief,
                :report,
                :path,
                :sha,
                :title,
                :beads_epic_id
              ]),
              fn {k, v} -> {to_string(k), v} end
            )

          payload = if opts[:spec], do: Map.put(payload, "spec_link", opts[:spec]), else: payload

          payload =
            if opts[:design], do: Map.put(payload, "design_link", opts[:design]), else: payload

          payload =
            if length(rest) == 2, do: Map.put(payload, "body", List.last(rest)), else: payload

          request = %{
            "action" => if(event, do: "event", else: verb),
            "kind" => kind,
            "event" => event,
            "id" => id,
            "payload" => payload,
            "actor" =>
              opts[:actor] || defaults[:actor] || System.get_env("FOREMAN_ACTOR", "user"),
            "session" =>
              opts[:session] || defaults[:session] || System.get_env("FOREMAN_SESSION"),
            "project" => opts[:project] || opts[:repo],
            "cwd" => defaults[:cwd] || File.cwd!(),
            "epic" => opts[:epic],
            "epic_project" => opts[:epic_project],
            "stage" => opts[:stage]
          }

          {:ok, %{request: request, json: opts[:json] || false}}
        else
          {:error, :usage}
        end

      _ ->
        {:error, :usage}
    end
  end
end
