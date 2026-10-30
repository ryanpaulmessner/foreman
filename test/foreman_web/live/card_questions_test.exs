defmodule ForemanWeb.CardQuestionsTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.{CardMessages, Requests}
  import Mimic
  setup :set_mimic_global

  setup do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Ticket", issue_type: "task", status: "open"})
    )

    {:ok, r} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "build",
        "facts" => %{"question" => "Which?"}
      })

    %{request: r}
  end

  test "the box sends a question and keeps the request pending", %{conn: conn, request: r} do
    register(r)

    expect(Foreman.SessionTmux, :reply_source, fn source, text, [] ->
      assert source.target == "%42"
      assert text == "[card question #{r.id}] Why this option?"
      :ok
    end)

    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#card-question-send-#{r.id}")

    view
    |> form("#card-question-form-#{r.id}", card_question: %{text: "Why this option?"})
    |> render_submit()

    assert has_element?(view, "#request-#{r.id} [data-card-message]", "Why this option?")
    assert Requests.get(r.id).state == "pending"
  end

  test "a closed session explains the failure and keeps a session command", %{
    conn: conn,
    request: r
  } do
    register(r)
    expect(Foreman.SessionTmux, :reply_source, fn _, _, _ -> {:error, :window_gone} end)
    {:ok, view, _} = live(conn, "/needs-you")
    view |> form("#card-question-form-#{r.id}", card_question: %{text: "Why?"}) |> render_submit()
    assert has_element?(view, "#card-question-unavailable-#{r.id}", "window is closed")
    assert has_element?(view, "#card-question-text-#{r.id}", "Why?")
    assert has_element?(view, "#card-question-copy-#{r.id}", "[card question #{r.id}] Why?")
    assert has_element?(view, "#card-question-retry-#{r.id}")
    assert has_element?(view, "#go-session-#{r.id}")
    assert has_element?(view, "#card-conversation-#{r.id} code", "tmux select-window")
    assert CardMessages.list(r.id) == []
  end

  test "failed questions keep their draft and can be retried in page and drawer", %{
    conn: conn,
    request: r
  } do
    register(r)
    stub(Foreman.SessionTmux, :reply_source, fn _, _, _ -> {:error, :prompt_busy} end)
    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")

    for prefix <- ["", "drawer-"] do
      view
      |> form("##{prefix}card-question-form-#{r.id}", card_question: %{text: "Why this option?"})
      |> render_submit()

      assert has_element?(view, "##{prefix}card-question-text-#{r.id}", "Why this option?")

      assert has_element?(
               view,
               "##{prefix}card-question-copy-#{r.id}",
               "[card question #{r.id}] Why this option?"
             )

      assert has_element?(view, "##{prefix}card-question-unavailable-#{r.id}", "empty prompt")
      view |> element("##{prefix}card-question-retry-#{r.id}") |> render_click()
      send(view.pid, :reconcile)
      assert has_element?(view, "##{prefix}card-question-text-#{r.id}", "Why this option?")
      assert has_element?(view, "##{prefix}card-question-send-#{r.id}")
    end

    assert CardMessages.list(r.id) == []
    stub(Foreman.SessionTmux, :reply_source, fn _, _, _ -> :ok end)

    view
    |> form("#card-question-form-#{r.id}", card_question: %{text: "Why this option?"})
    |> render_submit()

    assert [%{body: "Why this option?"}] = CardMessages.list(r.id)
  end

  test "closed sessions supersede questioned cards and keep the thread in outcomes", %{
    conn: conn,
    request: r
  } do
    r =
      r
      |> Ecto.Changeset.change(
        kind: "session_waiting",
        facts: %{
          "target" => "external",
          "window" => "@8",
          "reason" => "question",
          "question" => "Which?"
        }
      )
      |> Foreman.Repo.update!()

    Foreman.Repo.insert!(%Foreman.CardMessage{request_id: r.id, author: "ryan", body: "Why?"})
    {:ok, view, _} = live(conn, "/needs-you")
    stub(Foreman.SessionTmux, :external_target, fn _ -> {:error, :window_gone} end)
    assert :ok = Foreman.SessionWaiting.reconcile_external()
    assert :ok = Foreman.SessionWaiting.reconcile_external()
    assert Requests.get(r.id).state == "superseded"
    assert Foreman.SessionWaiting.pending({r.repo_key, r.bead_id}, r.session) == []

    send(
      view.pid,
      {:notification, :foreman_events, %{"kind" => "requests_changed", "key" => r.id}}
    )

    refute has_element?(view, "#request-#{r.id}")
    assert has_element?(view, "#recent-requests [data-card-message]", "Why?")
  end

  test "recent outcomes batch messages and do not resolve finished session sources", %{
    conn: conn,
    request: r
  } do
    for n <- 1..3 do
      {:ok, request} =
        Requests.ask({r.repo_key, r.bead_id}, "decision", %{
          "actor" => "pi",
          "session" => "build-#{n}",
          "facts" => %{"question" => "Which #{n}?"}
        })

      {:ok, _} = CardMessages.reply(request.id, "pi", nil, "Reply #{n}")
      {:ok, _} = Requests.withdraw_from_card(request.id, "Finished")
    end

    {:ok, _} = Requests.withdraw_from_card(r.id, "Finished")
    {:ok, view, _} = live(conn, "/needs-you")
    handler = "card-query-#{r.id}"

    :telemetry.attach(
      handler,
      [:foreman, :repo, :query],
      fn _, _, meta, {owner, pid} ->
        if self() == pid, do: send(owner, {:card_query, meta.query})
      end,
      {self(), view.pid}
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(view.pid, :reconcile)

    for n <- 1..3,
        do: assert(has_element?(view, "#recent-requests [data-card-message]", "Reply #{n}"))

    queries = drain_queries([])

    assert Enum.count(
             queries,
             &(String.contains?(&1, "FROM \"card_messages\"") and not String.contains?(&1, "max("))
           ) == 1

    refute Enum.any?(queries, &String.contains?(&1, "FROM \"sessions\""))
    refute Enum.any?(queries, &String.contains?(&1, "FROM \"planning_sessions\""))
  end

  defp drain_queries(queries) do
    receive do
      {:card_query, query} -> drain_queries([query | queries])
    after
      0 -> queries
    end
  end

  defp register(r) do
    Foreman.Repo.insert_all("sessions", [
      %{
        repo_key: "sample",
        bead_id: "s-1",
        window: "%42",
        details: %{"session" => "build", "harness" => "pi"},
        last_seen_at: r.inserted_at,
        started_at: DateTime.add(r.inserted_at, -1)
      }
    ])
  end

  test "unknown source shows a fallback instead of a send button", %{conn: conn, request: r} do
    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#card-question-#{r.id}", "Ask about this")
    assert has_element?(view, "#card-question-unavailable-#{r.id}", "Source unknown")
    refute has_element?(view, "#card-question-send-#{r.id}")
    assert has_element?(view, "#card-question-copy-#{r.id}", "[card question #{r.id}]")
  end

  test "replies update the card and drawer without reload and survive withdrawal", %{
    conn: conn,
    request: r
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")
    {:ok, message} = CardMessages.reply(r.id, "pi", "build", "**Because**")

    send(
      view.pid,
      {:notification, :foreman_events, %{"kind" => "requests_changed", "key" => r.id}}
    )

    for prefix <- ["", "drawer-"] do
      assert has_element?(view, "##{prefix}card-message-#{message.id} strong", "Because")
    end

    view |> form("#withdraw-#{r.id}", withdraw: %{reason: "No longer needed"}) |> render_submit()
    assert has_element?(view, "#recent-requests [data-card-message] strong", "Because")
  end
end
