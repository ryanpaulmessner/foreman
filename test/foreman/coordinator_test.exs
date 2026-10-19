defmodule Foreman.CoordinatorTest do
  use Foreman.DataCase, async: false
  alias Foreman.Sessions

  test "stale coordinator hooks cannot fall back to external session tracking" do
    assert {:error, :unknown_session} =
             Foreman.SessionWaiting.ask(Sessions.coordinator_key(), %{
               "session" => Ecto.UUID.generate(),
               "facts" => %{"reason" => "input"}
             })
  end

  test "adoption cannot take another planning conversation's identity" do
    id = Ecto.UUID.generate()

    Foreman.Repo.insert!(%Foreman.PlanningSession{
      session_id: id,
      project: "sample",
      ticket: "x-1",
      workdir: "/tmp",
      state: :ended,
      launched_at: DateTime.utc_now()
    })

    assert Sessions.prepare_coordinator({:adopt, id}) == {:error, :session_id_in_use}
    assert is_nil(Sessions.coordinator())
  end

  test "a failed fresh launch preserves the recorded conversation" do
    {:ok, before, :adopt} = Sessions.prepare_coordinator({:adopt, Ecto.UUID.generate()})

    assert {:error, _} =
             Sessions.launch_coordinator(:fresh,
               executable: "/no/such/claude",
               workdir: File.cwd!(),
               socket: "fm-coordinator-missing-test-socket"
             )

    assert Sessions.coordinator().session_id == before.session_id
  end

  test "a rejected pane command returns a refusal without aborting its caller" do
    {:ok, before, :adopt} = Sessions.prepare_coordinator({:adopt, Ecto.UUID.generate()})

    assert {422, %{error: :invalid_coordinator_pane}} =
             Foreman.AgentCommands.execute(%{
               "action" => "coordinator",
               "mode" => "fresh",
               "pane" => "not-a-pane",
               "socket" => "not-a-socket"
             })

    assert Sessions.coordinator().session_id == before.session_id
  end

  test "coordinator waits reach the inbox without a ticket or project" do
    {:ok, s, :fresh} = Sessions.prepare_coordinator(:resume, window: "@123")
    key = Sessions.coordinator_key()
    {project, ticket} = key

    assert {200, %{id: id}} =
             Foreman.AgentCommands.execute(%{
               "action" => "ask",
               "request_kind" => "session_waiting",
               "id" => ticket,
               "project" => project,
               "session" => s.session_id,
               "facts" => %{"reason" => "usage_limit", "provider" => "Anthropic"}
             })

    assert Foreman.Requests.get(id).state == "pending"
    assert Sessions.coordinator().state == :waiting

    assert {200, _} =
             Foreman.AgentCommands.execute(%{
               "action" => "session_resumed",
               "id" => ticket,
               "project" => project,
               "session" => s.session_id
             })

    assert Foreman.Requests.get(id).state == "superseded"
  end

  defp coordinator_hook(session, event, input) do
    {project, ticket} = Sessions.coordinator_key()
    base = %{"id" => ticket, "project" => project, "session" => session.session_id}

    case Foreman.SessionHooks.facts(event, input) do
      {:waiting, facts} ->
        Foreman.AgentCommands.execute(
          Map.merge(base, %{
            "action" => "ask",
            "request_kind" => "session_waiting",
            "facts" => facts
          })
        )

      {:resumed, tool} ->
        Foreman.AgentCommands.execute(
          Map.merge(base, %{"action" => "session_resumed", "resume_tool" => tool})
        )
    end
  end

  test "an idle coordinator Stop records waiting without a Needs you request" do
    {:ok, s, :fresh} = Sessions.prepare_coordinator(:resume, window: "@123")

    assert {200, %{state: :waiting}} = coordinator_hook(s, "Stop", %{})
    assert Foreman.Requests.pending() == []
    assert Foreman.Requests.pending_count() == 0
    assert Sessions.coordinator().state == :waiting

    assert {200, %{state: :running}} = coordinator_hook(s, "PreToolUse", %{"tool_name" => "Bash"})
    assert Sessions.coordinator().state == :running
  end

  test "coordinator questions and permissions still reach Needs you and clear on resume" do
    {:ok, s, :fresh} = Sessions.prepare_coordinator(:resume, window: "@123")
    question = %{"tool_name" => "AskUserQuestion", "tool_input" => %{"questions" => [%{}]}}
    permission = %{"tool_name" => "Bash", "tool_input" => %{"command" => "ls"}}

    for {event, input} <- [{"PreToolUse", question}, {"PermissionRequest", permission}] do
      assert {200, %{id: id}} = coordinator_hook(s, event, input)
      assert [%{id: ^id}] = Foreman.Requests.pending()
      assert Sessions.coordinator().state == :waiting
      assert {200, %{state: :running}} = coordinator_hook(s, "PostToolUse", input)
      assert Foreman.Requests.get(id).state == "superseded"
      assert Foreman.Requests.pending() == []
    end
  end

  test "an idle coordinator Stop supersedes an idle request recorded before the change" do
    {:ok, s, :fresh} = Sessions.prepare_coordinator(:resume, window: "@123")

    {:ok, old} =
      Foreman.Requests.create(Sessions.coordinator_key(), "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{"reason" => "input", "target" => "planning"}
      })

    assert {200, %{state: :waiting}} = coordinator_hook(s, "Stop", %{})
    assert Foreman.Requests.get(old.id).state == "superseded"
    assert Foreman.Requests.pending() == []
  end

  test "a coordinator Stop that ends on a question raises one question request" do
    {:ok, s, :fresh} = Sessions.prepare_coordinator(:resume, window: "@123")
    stop = %{"last_assistant_message" => "Reviewed clean.\n\nShall I commit it?"}

    assert {200, %{id: id}} = coordinator_hook(s, "Stop", stop)
    assert [%{id: ^id, facts: facts}] = Foreman.Requests.pending()
    assert facts["reason"] == "question"
    assert facts["question"] == "Shall I commit it?"
    assert Sessions.coordinator().state == :waiting

    # A repeated hook for the same turn does not duplicate the card.
    assert {200, %{id: ^id}} = coordinator_hook(s, "Stop", stop)
    assert [%{id: ^id}] = Foreman.Requests.pending()

    assert {200, %{state: :running}} = coordinator_hook(s, "UserPromptSubmit", %{})
    assert Foreman.Requests.get(id).state == "superseded"
    assert Foreman.Requests.pending() == []
  end

  test "a later Stop without a question clears the question card; a new question replaces it" do
    {:ok, s, :fresh} = Sessions.prepare_coordinator(:resume, window: "@123")

    assert {200, %{id: first}} =
             coordinator_hook(s, "Stop", %{"last_assistant_message" => "Push now?"})

    assert {200, %{id: second}} =
             coordinator_hook(s, "Stop", %{"last_assistant_message" => "Merge now?"})

    assert first != second
    assert Foreman.Requests.get(first).state == "superseded"

    assert {200, %{state: :waiting}} =
             coordinator_hook(s, "Stop", %{"last_assistant_message" => "Merged."})

    assert Foreman.Requests.get(second).state == "superseded"
    assert Foreman.Requests.pending() == []
  end

  test "background activity after a question Stop clears the card" do
    {:ok, s, :fresh} = Sessions.prepare_coordinator(:resume, window: "@123")

    assert {200, %{id: id}} =
             coordinator_hook(s, "Stop", %{"last_assistant_message" => "Push now?"})

    assert {200, %{state: :running}} = coordinator_hook(s, "PreToolUse", %{"tool_name" => "Bash"})
    assert Foreman.Requests.get(id).state == "superseded"
  end

  test "an idle coordinator Stop keeps a permission prompt that is still open" do
    {:ok, s, :fresh} = Sessions.prepare_coordinator(:resume, window: "@123")
    permission = %{"tool_name" => "Bash", "tool_input" => %{"command" => "ls"}}

    assert {200, %{id: id}} = coordinator_hook(s, "PermissionRequest", permission)
    assert {200, %{state: :waiting}} = coordinator_hook(s, "Stop", %{})
    assert [%{id: ^id}] = Foreman.Requests.pending()
  end

  test "coordinator adoption is an authenticated command independent of the project catalog" do
    id = "1edc88cf-b665-4ce3-adc4-f1bd434c64f2"

    assert {200, %{session_id: ^id}} =
             Foreman.AgentCommands.execute(%{
               "action" => "coordinator",
               "mode" => "adopt",
               "adopt" => id
             })
  end

  test "fresh replaces the conversation and adopt records an existing UUID" do
    {:ok, first, :fresh} = Sessions.prepare_coordinator(:resume)
    assert {:ok, fresh, :fresh} = Sessions.prepare_coordinator(:fresh)
    refute fresh.session_id == first.session_id
    id = "1edc88cf-b665-4ce3-adc4-f1bd434c64f2"
    assert {:ok, adopted, :adopt} = Sessions.prepare_coordinator({:adopt, id})
    assert adopted.state == :ended
    assert {:ok, resumed, :resume} = Sessions.prepare_coordinator(:resume)
    assert resumed.session_id == id
    assert Sessions.prepare_coordinator({:adopt, "bad"}) == {:error, :invalid_session_id}
  end

  test "a new coordinator is recorded globally and the next launch resumes its identity" do
    assert {:ok, first, :fresh} = Sessions.prepare_coordinator(:resume)
    assert first.workdir == Path.expand("~/dev/music")
    assert Sessions.coordinator().session_id == first.session_id
    assert {:ok, second, :resume} = Sessions.prepare_coordinator(:resume)
    assert second.session_id == first.session_id
  end
end
