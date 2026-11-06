defmodule ForemanWeb.EndedSessionCardLiveTest do
  @moduledoc """
  A card whose session ended (spec R9, Decision 21): the Asked by row says where the
  answer goes, and answering sends it there or keeps the card open with the reason.
  tmux is a stand-in; nothing starts a real agent.
  """
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, Requests}

  setup do
    on_exit(fn ->
      Application.put_env(:foreman, :session_controls_tmux, runner: &Foreman.TestTmux.no_panes/3)
    end)

    coordinator =
      agent_session(name: "fm-epic", kind: "epic_coordinator", harness: "claude", pane_id: "%1")

    build = agent_session(name: "build-asked", parent_id: coordinator.id, pane_id: "%5")

    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "foreman",
        bead_id: "fm-9mm.15",
        kind: "decision",
        actor: "pi",
        state: "pending",
        session: build.name,
        agent_session_id: build.id,
        facts: %{"question" => "Keep the confirm?", "options" => ["Keep it", "Drop it"]}
      })

    AgentSessions.end_session(build)
    %{request: request}
  end

  # Claude's prompt in the coordinator's pane is idle (`screen`); every typed line is sent
  # to the test.
  defp tmux(screen) do
    test = self()

    runner = fn "tmux", args, _ ->
      cond do
        "list-panes" in args -> {"%1\t@1\tforeman\tfm-epic\t1\n", 0}
        "capture-pane" in args -> {screen, 0}
        "-l" in args -> send(test, {:typed, List.last(args)}) && {"", 0}
        true -> {"", 0}
      end
    end

    Application.put_env(:foreman, :session_controls_tmux, runner: runner, key_delay: 0)
  end

  test "the Asked by row says the answer goes to the coordinator", %{conn: conn, request: r} do
    {:ok, view, _} = live(conn, "/needs-you?card=#{r.id}")
    assert has_element?(view, "#card-source-#{r.id}", "ended")
    assert has_element?(view, "#card-source-#{r.id}", "answer goes to fm-epic")
    refute has_element?(view, "#card-source-#{r.id}", "your answer resumes it")
  end

  test "answering sends the coordinator the question and answer and closes the card (acceptance 9)",
       %{conn: conn, request: r} do
    tmux("───\n❯ \n───\n")
    {:ok, view, _} = live(conn, "/needs-you?card=#{r.id}")

    view
    |> form("#decision-#{r.id}", decision: %{choice: "Keep it"})
    |> render_submit(%{"action" => "answer"})

    assert_received {:typed, typed}
    assert typed =~ "[foreman note from board] build-asked ended and cannot resume."
    assert typed =~ "Question: Keep the confirm? Answer: Keep it"
    assert %{state: "answered"} = Requests.get(r.id)
    assert has_element?(view, "#card-result-#{r.id}", "Sent to fm-epic")
    assert has_element?(view, "#card-result-#{r.id}", "as a note with the question.")
  end

  test "a busy coordinator: the card stays open and says why", %{conn: conn, request: r} do
    tmux("✳ Working… (3s)\n───\n❯ \n───\nesc to interrupt\n")
    {:ok, view, _} = live(conn, "/needs-you?card=#{r.id}")

    view
    |> form("#decision-#{r.id}", decision: %{choice: "Keep it"})
    |> render_submit(%{"action" => "answer"})

    refute_received {:typed, _}
    assert %{state: "pending"} = Requests.get(r.id)

    assert has_element?(
             view,
             "#request-#{r.id}",
             "The board could not send it: fm-epic is busy. The card stays open."
           )
  end

  test "a session that can resume: answering resumes it first and the line says so", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "ec-card-#{System.unique_integer([:positive])}")
    sessions = Path.join(root, "pi-sessions")
    dir = Path.join(root, "wt")
    File.mkdir_p!(dir)
    id = Ecto.UUID.generate()
    project = "--" <> (dir |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"
    File.mkdir_p!(Path.join(sessions, project))
    File.write!(Path.join([sessions, project, "x_" <> id <> ".jsonl"]), "{}\n")
    File.write!(Path.join(root, "pi"), "#!/bin/sh\n")
    File.chmod!(Path.join(root, "pi"), 0o700)
    Application.put_env(:foreman, :pi_sessions_dir, sessions)

    on_exit(fn ->
      Application.delete_env(:foreman, :pi_sessions_dir)
      File.rm_rf(root)
    end)

    build = agent_session(name: "build-back", conversation_id: id, workdir: dir, pane_id: "%6")

    r =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "foreman",
        bead_id: "fm-9mm.15",
        kind: "decision",
        actor: "pi",
        state: "pending",
        agent_session_id: build.id,
        facts: %{"question" => "Use the window?", "options" => ["Yes", "No"]}
      })

    AgentSessions.end_session(build)

    Application.put_env(:foreman, :session_controls_tmux,
      runner: fn "tmux", args, _ ->
        if Enum.any?(args, &(&1 in ~w(new-window new-session))), do: {"%43\n", 0}, else: {"", 0}
      end,
      executables: %{"pi" => Path.join(root, "pi")}
    )

    {:ok, view, _} = live(conn, "/needs-you?card=#{r.id}")
    assert has_element?(view, "#card-source-#{r.id}", "your answer resumes it")

    view
    |> form("#decision-#{r.id}", decision: %{choice: "Yes"})
    |> render_submit(%{"action" => "answer"})

    assert %{state: "starting", pane_id: "%43"} = AgentSessions.get(build.id)
    assert has_element?(view, "#card-result-#{r.id}", "Sent to build-back")
    assert has_element?(view, "#card-result-#{r.id}", "The board resumed it first.")
  end
end
