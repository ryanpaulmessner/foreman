defmodule Foreman.CardMessagesTest do
  use Foreman.DataCase, async: false
  alias Foreman.{CardMessages, Requests}
  import Mimic
  setup :set_mimic_global

  setup do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Ticket", issue_type: "task", status: "open"})
    )

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "build",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      })

    %{request: request}
  end

  test "questions reach Claude and Pi panes and leave the card pending", %{request: r} do
    for harness <- ["claude", "pi"] do
      Repo.insert_all("sessions", [
        %{
          repo_key: "sample",
          bead_id: "s-1",
          window: "%42",
          details: %{"session" => "build", "harness" => harness},
          last_seen_at: r.inserted_at,
          started_at: DateTime.add(r.inserted_at, -1)
        }
      ])

      parent = self()

      runner = fn "tmux", args, _ ->
        case Enum.drop(args, 3) do
          ["list-panes" | _] ->
            {"%42\t@8\tsample\tbuild\t1\n", 0}

          ["display-message" | _] ->
            {"node\tpi --name build", 0}

          ["capture-pane" | _] ->
            if harness == "pi", do: {"───\n\n───\nfooter", 0}, else: {"───\n❯\n───", 0}

          ["send-keys", "-t", "%42", "-l", "--", text] ->
            send(parent, {:typed, text})
            {"", 0}

          ["send-keys", "-t", "%42", "Enter"] ->
            send(parent, :entered)
            {"", 0}
        end
      end

      assert {:ok, message} = CardMessages.ask(r.id, "Why?", runner: runner, key_delay: 0)
      assert message.author == "ryan"
      assert message.body == "Why?"
      assert_receive {:typed, text}
      assert text == "[card question #{r.id}] Why?"
      assert_receive :entered
      assert Requests.get(r.id).state == "pending"
    end

    assert length(CardMessages.list(r.id)) == 2
  end

  test "board Claude delivery checks the stored conversation identity", %{request: r} do
    session =
      Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "s-1",
        window: "@8",
        workdir: "/tmp",
        state: :waiting,
        launched_at: r.inserted_at,
        last_activity_at: r.inserted_at
      })

    r = r |> Ecto.Changeset.change(session: session.session_id) |> Repo.update!()

    runner = fn _, args, _ ->
      assert Enum.take(args, 6) == ["-u", "-N", "-L", "foreman", "-f", "/dev/null"]

      case Enum.drop(args, 6) do
        ["list-windows" | _] ->
          {"sample\ts-1\t@8\trunning\t0\t#{session.session_id}\n", 0}

        ["display-message" | _] ->
          {"#{session.session_id} %42", 0}

        ["capture-pane" | _] ->
          {"───\n❯\n───", 0}

        ["send-keys", "-t", "%42", "-l", "--", text] ->
          assert text == "[card question #{r.id}] Why?"
          {"", 0}

        ["send-keys", "-t", "%42", "Enter"] ->
          {"", 0}
      end
    end

    assert {:ok, _} = CardMessages.ask(r.id, "Why?", runner: runner, key_delay: 0)
    assert Requests.get(r.id).state == "pending"
  end

  test "external waiting cards refuse a replaced pane process", %{request: r} do
    assert {:ok, _} =
             Foreman.SessionRegistry.register(%{
               "name" => r.session,
               "pane" => "%42",
               "workdir" => "/tmp",
               "harness" => "pi"
             })

    r =
      r
      |> Ecto.Changeset.change(
        kind: "session_waiting",
        facts: %{"target" => "external", "window" => "@8", "pane" => "%42", "pid" => "old"}
      )
      |> Repo.update!()

    runner = fn _, args, _ ->
      case Enum.drop(args, 3) do
        ["list-panes" | _] -> {"sample\tbuild\t@8\t%42\tnew\t1\n", 0}
        ["capture-pane" | _] -> {"───\n❯\n───", 0}
      end
    end

    assert {:error, :window_gone} = CardMessages.ask(r.id, "Why?", runner: runner)
    assert CardMessages.list(r.id) == []
  end

  test "Pi refuses a draft even when prior output contains an empty box", %{request: r} do
    Repo.insert_all("sessions", [
      %{
        repo_key: "sample",
        bead_id: "s-1",
        window: "%42",
        details: %{"session" => "build", "harness" => "pi"},
        last_seen_at: r.inserted_at,
        started_at: DateTime.add(r.inserted_at, -1)
      }
    ])

    runner = fn _, args, _ ->
      case Enum.drop(args, 3) do
        ["list-panes" | _] -> {"%42\t@8\tsample\tbuild\t1\n", 0}
        ["display-message" | _] -> {"node\tpi --name build", 0}
        ["capture-pane" | _] -> {"───\n\n───\n───\nunsent draft\n───\nfooter", 0}
        ["send-keys" | _] -> {"", 0}
      end
    end

    assert {:error, :prompt_busy} = CardMessages.ask(r.id, "Why?", runner: runner, key_delay: 0)
    assert CardMessages.list(r.id) == []
  end

  test "unknown, gone and busy sessions store no question", %{request: r} do
    assert {:error, :source_unknown} = CardMessages.ask(r.id, "Why?")

    Repo.insert_all("sessions", [
      %{
        repo_key: "sample",
        bead_id: "s-1",
        window: "%42",
        details: %{"session" => "build", "harness" => "claude"},
        last_seen_at: r.inserted_at,
        started_at: DateTime.add(r.inserted_at, -1)
      }
    ])

    assert {:error, :window_gone} =
             CardMessages.ask(r.id, "Why?", runner: fn _, _, _ -> {"", 0} end)

    runner = fn _, args, _ ->
      case Enum.drop(args, 3) do
        ["list-panes" | _] -> {"%42\t@8\tsample\tbuild\t1\n", 0}
        ["capture-pane" | _] -> {"$ shell prompt", 0}
      end
    end

    assert {:error, :prompt_busy} = CardMessages.ask(r.id, "Why?", runner: runner)
    assert CardMessages.list(r.id) == []
    assert Requests.get(r.id).state == "pending"
  end

  test "new session questions deduplicate alongside an open card thread", %{request: r} do
    r =
      r
      |> Ecto.Changeset.change(
        kind: "session_waiting",
        facts: %{"reason" => "question", "question" => "Old?"}
      )
      |> Repo.update!()

    Repo.insert!(%Foreman.CardMessage{request_id: r.id, author: "ryan", body: "Why?"})

    stub(Foreman.SessionTmux, :external_target, fn "build" ->
      {:ok,
       %{
         "target" => "external",
         "window" => "@8",
         "pane" => "%42",
         "pid" => "42",
         "snapshot" => "hash"
       }}
    end)

    params = %{
      "actor" => "pi",
      "session" => "build",
      "facts" => %{"reason" => "question", "question" => "New?", "window" => "build"}
    }

    assert {:ok, next} = Foreman.SessionWaiting.ask({r.repo_key, r.bead_id}, params)
    assert {:ok, repeated} = Foreman.SessionWaiting.ask({r.repo_key, r.bead_id}, params)
    assert repeated.id == next.id
    assert Requests.get(r.id).state == "pending"
  end

  test "session resume hooks do not close a card with a question thread", %{request: r} do
    r =
      r
      |> Ecto.Changeset.change(
        kind: "session_waiting",
        facts: %{"reason" => "question", "question" => "Which?"}
      )
      |> Repo.update!()

    Repo.insert!(%Foreman.CardMessage{request_id: r.id, author: "ryan", body: "Why?"})
    Foreman.SessionWaiting.clear({r.repo_key, r.bead_id}, r.session)
    assert Requests.get(r.id).state == "pending"
  end

  test "refuses missing and finished requests", %{request: r} do
    assert {:error, :not_found} = CardMessages.reply("bad", "pi", nil, "Reply")

    for state <- ~w(answered declined withdrawn done failed superseded approved executing) do
      r |> Ecto.Changeset.change(state: state) |> Repo.update!()
      assert {:error, :request_finished} = CardMessages.reply(r.id, "pi", nil, "Reply")
    end

    assert CardMessages.list(r.id) == []
  end

  test "refuses empty, invalid or oversized messages and missing authors", %{request: r} do
    for body <- [" ", nil, <<255>>, String.duplicate("a", 20_001)] do
      assert {:error, :invalid_message} = CardMessages.reply(r.id, "pi", nil, body)
    end

    assert {:error, :invalid_message} = CardMessages.reply(r.id, nil, nil, "Reply")
    assert CardMessages.list(r.id) == []
  end

  test "agent replies are kept in order without resolving the request", %{request: r} do
    assert {:ok, first} = CardMessages.reply(r.id, "pi", "build", "**First**")
    assert {:ok, second} = CardMessages.reply(r.id, "claude", nil, "Second")

    assert Enum.map(CardMessages.list(r.id), &{&1.id, &1.author, &1.body}) == [
             {first.id, "pi · build", "**First**"},
             {second.id, "claude", "Second"}
           ]

    assert Requests.get(r.id).state == "pending"
  end
end
