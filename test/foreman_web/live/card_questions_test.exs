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
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      })

    %{request: r}
  end

  defp ask(view, r, text, prefix \\ "") do
    view
    |> form("##{prefix}decision-#{r.id}", decision: %{note: text})
    |> render_submit(%{"action" => "ask"})
  end

  test "Ask sends the text as a question and keeps the request pending", %{
    conn: conn,
    request: r
  } do
    register(r)

    expect(Foreman.SessionTmux, :reply_source, fn source, text, [] ->
      assert source.target == "%42"
      assert text == "[card question #{r.id}] Why this option?"
      :ok
    end)

    {:ok, view, _} = live(conn, "/needs-you")

    assert has_element?(
             view,
             ~s(#card-ask-#{r.id}[title="Goes to build. The reply shows on this card."])
           )

    ask(view, r, "Why this option?")

    assert has_element?(view, "#request-#{r.id} [data-card-message]", "Why this option?")
    assert Requests.get(r.id).state == "pending"
    # A sent question clears the text box (CardAsk: sent).
    assert has_element?(view, "#card-text-#{r.id}")
    refute has_element?(view, "#card-text-#{r.id}", "Why this option?")
    refute has_element?(view, "#card-question-copy-#{r.id}")
  end

  test "a closed session explains the failure and keeps the copy field", %{
    conn: conn,
    request: r
  } do
    register(r)
    expect(Foreman.SessionTmux, :reply_source, fn _, _, _ -> {:error, :window_gone} end)
    {:ok, view, _} = live(conn, "/needs-you")
    ask(view, r, "Why?")
    assert has_element?(view, "#card-question-unavailable-#{r.id}", "window is closed")
    assert has_element?(view, "#card-text-#{r.id}", "Why?")

    assert has_element?(
             view,
             ~s(#card-question-copy-#{r.id} input[value="[card question #{r.id}] Why?"])
           )

    assert has_element?(view, "#card-question-unavailable-#{r.id}.bb-status-error")
    assert has_element?(view, "#card-question-retry-#{r.id}", "Try again")
    assert has_element?(view, "#card-focus-#{r.id}:not([disabled])")
    refute render(view) =~ "tmux select-window"

    assert CardMessages.list(r.id) == []
  end

  test "failed questions keep their text and can be retried in page and drawer", %{
    conn: conn,
    request: r
  } do
    register(r)
    stub(Foreman.SessionTmux, :reply_source, fn _, _, _ -> {:error, :prompt_busy} end)
    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")

    for prefix <- ["", "drawer-"] do
      ask(view, r, "Why this option?", prefix)
      assert has_element?(view, "##{prefix}card-text-#{r.id}", "Why this option?")

      assert has_element?(
               view,
               ~s(##{prefix}card-question-copy-#{r.id} input[value="[card question #{r.id}] Why this option?"])
             )

      assert has_element?(view, "##{prefix}card-question-unavailable-#{r.id}", "empty prompt")
      # Try again sends the same question again; it fails the same way.
      view |> element("##{prefix}card-question-retry-#{r.id}") |> render_click()
      send(view.pid, :reconcile)
      assert has_element?(view, "##{prefix}card-text-#{r.id}", "Why this option?")
      assert has_element?(view, "##{prefix}card-question-unavailable-#{r.id}", "empty prompt")
    end

    assert CardMessages.list(r.id) == []
    stub(Foreman.SessionTmux, :reply_source, fn _, _, _ -> :ok end)
    view |> element("#card-question-retry-#{r.id}") |> render_click()
    assert [%{body: "Why this option?"}] = CardMessages.list(r.id)
    refute has_element?(view, "#card-question-unavailable-#{r.id}")
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
          "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which #{n}?"})
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
    Foreman.AgentSessionFixtures.asked_by(
      r,
      Foreman.AgentSessionFixtures.agent_session(name: "build", pane_id: "%42")
    )
  end

  test "Ask on an unknown source shows the copy field instead of sending", %{
    conn: conn,
    request: r
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    ask(view, r, "Why?")

    assert has_element?(
             view,
             "#card-question-hint-#{r.id}",
             "The board cannot send this question, because it does not know which session asked."
           )

    refute has_element?(view, "#card-question-retry-#{r.id}")

    assert has_element?(
             view,
             ~s(#card-question-copy-#{r.id} input[value="[card question #{r.id}] Why?"][readonly])
           )

    assert CardMessages.list(r.id) == []
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

      assert view
             |> element("##{prefix}card-message-#{message.id} [data-card-message-author]")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.trim() == "build"
    end

    view
    |> form("#decision-#{r.id}", decision: %{note: "No longer needed"})
    |> render_submit(%{"action" => "withdraw"})

    assert has_element?(view, "#recent-requests [data-card-message] strong", "Because")
  end
end
