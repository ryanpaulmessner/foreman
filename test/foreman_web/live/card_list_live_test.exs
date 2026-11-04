defmodule ForemanWeb.CardListLiveTest do
  # The triage list on Needs you (question cards spec, Decisions 1-11, 29-32, 39;
  # ticket fm-zgd.17.3 acceptance).
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic
  alias Foreman.Requests
  setup :set_mimic_global

  setup do
    Foreman.Beads.Projection.replace(
      "sample",
      Enum.map_join(
        [{"s-1", "A ticket", 2}, {"s-2", "Urgent ticket", 0}],
        "\n",
        fn {id, title, priority} ->
          Jason.encode!(%{
            id: id,
            title: title,
            issue_type: "task",
            status: "open",
            priority: priority
          })
        end
      )
    )

    cards =
      for question <- ["First?", "Second?", "Third?"] do
        {:ok, request} =
          Requests.ask({"sample", "s-1"}, "decision", %{
            "actor" => "pi",
            "facts" =>
              Foreman.DecisionFacts.valid(%{
                "question" => question,
                "options" => ["Wide", "Compact"]
              })
          })

        request
      end

    # The result line's 10 s timer goes to the test, which fires it (an injected clock).
    test = self()

    Application.put_env(:foreman, :card_line_timer, fn pid, message, ms ->
      send(test, {:card_line_timer, pid, message, ms})
      make_ref()
    end)

    on_exit(fn -> Application.delete_env(:foreman, :card_line_timer) end)
    %{cards: cards}
  end

  defp open_cards(view) do
    view
    |> element("#pending-requests")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='card-open-']")
    |> Enum.count()
  end

  defp poll(view), do: send(view.pid, {:notification, :foreman_events, %{}})

  test "every pending card is one row and the first one is open", %{conn: conn, cards: cards} do
    [first, second, third] = cards
    {:ok, view, _} = live(conn, "/needs-you")
    assert open_cards(view) == 1
    assert has_element?(view, "#card-open-#{first.id}")

    for card <- [second, third] do
      row = "#card-row-#{card.id}"
      assert has_element?(view, row, "Decision")

      assert has_element?(
               view,
               "#{row} [title='#{card.facts["question"]}']",
               card.facts["question"]
             )

      assert has_element?(view, row, "source unknown")
      assert has_element?(view, "#{row} time[title]")
    end

    # Per-ticket headings went (Decision 6): the open card's header names the ticket.
    refute has_element?(view, "[data-ticket-heading]")
  end

  test "a row click opens that card and closes the other", %{conn: conn, cards: cards} do
    [first, second, _] = cards
    {:ok, view, _} = live(conn, "/needs-you")
    view |> element("#card-row-#{second.id}") |> render_click()
    assert_patch(view, "/needs-you?card=#{second.id}")
    assert open_cards(view) == 1
    assert has_element?(view, "#card-open-#{second.id}")
    assert has_element?(view, "#card-row-#{first.id}")
  end

  test "Close card leaves every card a row", %{conn: conn, cards: cards} do
    [first | _] = cards
    {:ok, view, _} = live(conn, "/needs-you?card=#{first.id}")
    view |> element("#card-close-#{first.id}") |> render_click()
    assert_patch(view, "/needs-you")
    assert open_cards(view) == 0
    assert has_element?(view, "#card-row-#{first.id}")
    poll(view)
    assert open_cards(view) == 0
  end

  test "the card in the URL opens on load", %{conn: conn, cards: [_, second, _]} do
    {:ok, view, _} = live(conn, "/needs-you?card=#{second.id}")
    assert has_element?(view, "#card-open-#{second.id}")
    assert open_cards(view) == 1
  end

  test "a stale card link opens the first card and says so", %{conn: conn, cards: cards} do
    [first, second, _] = cards
    {:ok, _} = Requests.resolve(second.id, :decline, %{})
    {:ok, view, _} = live(conn, "/needs-you?card=#{second.id}")
    assert has_element?(view, "#card-open-#{first.id}")

    assert has_element?(
             view,
             "#cards-notice",
             "That card is no longer open. Find it in Recent outcomes."
           )

    view |> element("#card-row-#{List.last(cards).id}") |> render_click()
    refute has_element?(view, "#cards-notice")
  end

  test "answering shows the result line, opens the next card, and the line goes after 10 s",
       %{conn: conn, cards: cards} do
    [first, second, _] = cards
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{choice: "Compact"})
    |> render_submit(%{"action" => "answer"})

    result = "#card-result-#{first.id}"
    assert has_element?(view, result, "Answered: Compact.")
    assert has_element?(view, result, "Saved just now.")
    assert has_element?(view, result, "It moves to Recent outcomes.")
    assert has_element?(view, "#{result} time[title]", "just now")
    assert has_element?(view, "#card-open-#{second.id}")
    assert open_cards(view) == 1
    assert_patch(view, "/needs-you?card=#{second.id}")

    assert_receive {:card_line_timer, pid, message, 10_000}
    # A poll in the 10 s keeps the line.
    poll(view)
    assert has_element?(view, result)
    send(pid, message)
    refute has_element?(view, result)
    assert has_element?(view, "#recent-requests", "First?")
  end

  test "the result line names a live session as the receiver", %{conn: conn, cards: [first | _]} do
    {:ok, %{id: session}} =
      Foreman.SessionRegistry.register(%{
        "name" => "build",
        "pane" => "%99999998",
        "workdir" => "/tmp",
        "harness" => "pi"
      })

    first |> Ecto.Changeset.change(agent_session_id: session) |> Foreman.Repo.update!()
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{note: "Use the old one"})
    |> render_submit(%{"action" => "answer"})

    assert has_element?(view, "#card-result-#{first.id}", "Answered with your note.")
    assert has_element?(view, "#card-result-#{first.id}", "Sent to build just now.")
  end

  test "the last card resolved shows the result line over the empty box", %{
    conn: conn,
    cards: cards
  } do
    for card <- Enum.drop(cards, 1), do: {:ok, _} = Requests.resolve(card.id, :decline, %{})
    [first | _] = cards
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{note: "No"})
    |> render_submit(%{"action" => "decline"})

    assert has_element?(view, "#card-result-#{first.id}", "Declined.")
    assert has_element?(view, "#inbox-empty", "Nothing waits on you.")
    assert open_cards(view) == 0
  end

  test "your choice and note survive switching cards and a poll", %{conn: conn, cards: cards} do
    [first, second, _] = cards
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{choice: "Wide", note: "Keep it short"})
    |> render_change()

    view |> element("#card-row-#{second.id}") |> render_click()
    poll(view)
    view |> element("#card-row-#{first.id}") |> render_click()
    assert has_element?(view, "#option-#{first.id}-0[checked]")
    refute has_element?(view, "#option-#{first.id}-1[checked]")
    assert has_element?(view, "#card-text-#{first.id}", "Keep it short")
  end

  test "a poll never resets the open card's form", %{conn: conn, cards: [first | _]} do
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{choice: "Compact", note: "Draft"})
    |> render_change()

    poll(view)
    assert has_element?(view, "#option-#{first.id}-1[checked]")
    assert has_element?(view, "#card-text-#{first.id}", "Draft")
  end

  test "a new card with a higher priority joins as a row and the open card stays", %{
    conn: conn,
    cards: [_, second, _]
  } do
    {:ok, view, _} = live(conn, "/needs-you?card=#{second.id}")

    {:ok, urgent} =
      Requests.ask({"sample", "s-2"}, "decision", %{
        "actor" => "pi",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Urgent?", "options" => ["Yes"]})
      })

    poll(view)
    assert has_element?(view, "#card-open-#{second.id}")
    assert has_element?(view, "#card-row-#{urgent.id}")
    assert open_cards(view) == 1
  end

  test "an empty list opens the card that arrives", %{conn: conn, cards: cards} do
    for card <- cards, do: {:ok, _} = Requests.resolve(card.id, :decline, %{})
    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#inbox-empty", "Nothing waits on you.")

    {:ok, new} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "New?", "options" => ["Yes"]})
      })

    poll(view)
    assert has_element?(view, "#card-open-#{new.id}")
    refute has_element?(view, "#inbox-empty")
  end

  test "a card answered in a second tab closes with a line and your note", %{
    conn: conn,
    cards: [first, second, _]
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    {:ok, other, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{note: "My unsent note"})
    |> render_change()

    other
    |> form("#decision-#{first.id}", decision: %{choice: "Wide"})
    |> render_submit(%{"action" => "answer"})

    poll(view)
    info = "#card-info-#{first.id}"
    assert has_element?(view, info, "This card closed elsewhere.")
    assert has_element?(view, info, "Answered")
    assert has_element?(view, info, "Your note was not sent:")
    assert has_element?(view, "#{info} input[value='My unsent note']")
    assert has_element?(view, "#card-open-#{second.id}")
    assert_patch(view, "/needs-you?card=#{second.id}")

    view |> element("#card-info-close-#{first.id}") |> render_click()
    refute has_element?(view, info)
  end

  test "a withdrawn card says the agent withdrew it", %{conn: conn, cards: [first | _]} do
    {:ok, view, _} = live(conn, "/needs-you")
    {:ok, _} = Requests.withdraw_from_card(first.id, "Not needed")
    poll(view)
    assert has_element?(view, "#card-info-#{first.id}", "Withdrawn by the agent")
    refute has_element?(view, "#card-info-#{first.id}", "Your note was not sent:")
  end

  test "a failed answer keeps the card open with your input, and Try again sends it", %{
    conn: conn,
    cards: [first | _]
  } do
    stub(Requests, :resolve, fn id, event, payload ->
      call_original(Requests, :resolve, [id, event, payload])
    end)

    expect(Requests, :resolve, fn _, _, _ ->
      raise DBConnection.ConnectionError, "timeout"
    end)

    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{choice: "Compact", note: "Keep"})
    |> render_change()

    view
    |> form("#decision-#{first.id}", decision: %{choice: "Compact", note: "Keep"})
    |> render_submit(%{"action" => "answer"})

    error = "#card-error-#{first.id}"
    assert has_element?(view, error, "Your answer was not sent.")
    assert has_element?(view, error, "The board could not save it: the database did not answer.")
    assert has_element?(view, error, "Your choice and note are still here.")
    assert has_element?(view, "#card-open-#{first.id}")
    assert has_element?(view, "#option-#{first.id}-1[checked]")
    assert has_element?(view, "#card-text-#{first.id}", "Keep")
    assert Requests.get(first.id).state == "pending"
    # The error stays across a poll (R9).
    poll(view)
    assert has_element?(view, error)

    # Try again sends the input kept now, edited after the failure.
    view
    |> form("#decision-#{first.id}", decision: %{choice: "Compact", note: "Keep it short"})
    |> render_change()

    view |> element("#card-retry-#{first.id}") |> render_click()

    assert %{state: "answered", outcome: %{"answer" => "Compact"}, note: "Keep it short"} =
             Requests.get(first.id)

    assert has_element?(view, "#card-result-#{first.id}", "Answered: Compact.")
    refute has_element?(view, error)
  end

  test "a query the database cancelled is the database not answering", %{
    conn: conn,
    cards: [first | _]
  } do
    expect(Requests, :resolve, fn _, _, _ ->
      raise %Postgrex.Error{
        postgres: %{code: :query_canceled, pg_code: "57014", message: "canceling statement"}
      }
    end)

    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{note: "Later"})
    |> render_submit(%{"action" => "decline"})

    assert has_element?(
             view,
             "#card-error-#{first.id}",
             "The board could not save it: the database did not answer."
           )
  end

  test "an action the board refuses says why", %{conn: conn, cards: [first | _]} do
    expect(Requests, :resolve, fn _, _, _ -> {:error, :invalid} end)
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{first.id}", decision: %{note: "Later"})
    |> render_submit(%{"action" => "decline"})

    assert has_element?(
             view,
             "#card-error-#{first.id}",
             "Your decline was not sent. The board could not save it: the board does not accept this action on this card."
           )

    refute render(view) =~ "Request not updated"
  end

  test "the list keeps its rows when it cannot load, and Try again loads it", %{
    conn: conn,
    cards: [first | _]
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    stub(Requests, :pending, fn -> raise DBConnection.ConnectionError, "timeout" end)
    poll(view)
    assert has_element?(view, "#cards-error", "Could not load cards.")
    assert has_element?(view, "#cards-error", "The database did not answer.")
    assert has_element?(view, "#card-open-#{first.id}")
    copy_original_pending()
    view |> element("#cards-error button", "Try again") |> render_click()
    refute has_element?(view, "#cards-error")
  end

  test "the page shows the loading skeleton before the list loads", %{conn: conn} do
    html = conn |> get("/needs-you") |> html_response(200)
    assert html =~ ~s(id="cards-loading")
    assert html =~ "Loading cards…"
  end

  defp copy_original_pending,
    do: stub(Requests, :pending, fn -> call_original(Requests, :pending, []) end)
end
