defmodule ForemanWeb.CardLifecycleLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.Requests

  setup do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Delivery", issue_type: "task", status: "open"})
    )

    {:ok, r} = ask("Which delivery date should we use?")
    %{request: r}
  end

  defp ask(question) do
    Requests.ask({"sample", "s-1"}, "decision", %{
      "actor" => "pi",
      "session" => "build",
      "facts" => Foreman.DecisionFacts.valid(%{"question" => question})
    })
  end

  test "a chore displays steps and one Done button that resumes its waiters", %{conn: conn} do
    {:ok, r} =
      Requests.ask({"sample", "s-1"}, "chore", %{
        "facts" => %{
          "question" => "Sign in",
          "steps" => ["Open preview", "Sign in to the account"]
        }
      })

    {:ok, view, _} = live(conn, "/needs-you?card=#{r.id}")
    assert has_element?(view, "#chore-steps-#{r.id} li", "Open preview")
    assert has_element?(view, "#submit-done-#{r.id}", "Done")
    refute has_element?(view, "#submit-answer-#{r.id}")
    refute has_element?(view, "#submit-decline-#{r.id}")

    view
    |> form("#chore-#{r.id}", chore: %{note: "Signed in as admin"})
    |> render_submit(%{"action" => "complete"})

    assert Requests.get(r.id).note == "Signed in as admin"
    assert Requests.get(r.id).state == "done"
    refute has_element?(view, "#request-#{r.id}")
  end

  test "a standing answer made before still refuses the ask and shows on Answers", %{
    conn: conn,
    request: r
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    refute has_element?(view, "#always-#{r.id}")
    {:ok, _} = Requests.resolve(r.id, :answer, %{"answer" => "Friday", "always" => true})

    [answer] = Foreman.Answers.standing()
    assert answer.answer == "Friday"
    assert {:error, %{standing_answer: %{answer: "Friday"}}} = ask(r.facts["question"])
    {:ok, answers, _} = live(conn, "/answers?tab=rules")
    assert has_element?(answers, "#always-rule-#{answer.id}", "Friday")
    answers |> element("#remove-standing-#{answer.id}") |> render_click()
    refute has_element?(answers, "#always-rule-#{answer.id}")
    assert Foreman.Answers.standing() == []
    assert {:ok, _} = ask(r.facts["question"])
  end

  test "Wrong question ends the card with the text as its reason", %{conn: conn, request: r} do
    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#card-wrong-question-#{r.id}[disabled]")

    view
    |> form("#decision-#{r.id}", decision: %{note: "The date has passed"})
    |> render_submit(%{"action" => "wrong-question"})

    refute has_element?(view, "#request-#{r.id}")
    assert Requests.get(r.id).state == "wrong_question"
    assert Requests.get(r.id).note == "The date has passed"
  end

  test "edits appear on the mounted card with an Updated time", %{conn: conn, request: r} do
    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")
    {:ok, _} = Requests.update(r.id, "pi", "build", %{"question" => "Which Friday?"})
    send(view.pid, :reconcile)
    assert has_element?(view, "#question-#{r.id}", "Which Friday?")
    assert has_element?(view, "#updated-#{r.id}", "Updated")
    assert has_element?(view, "#drawer-question-#{r.id}", "Which Friday?")
    open_from_drawer(view, r.id)
    assert has_element?(view, "#updated-#{r.id}", "Updated")
  end

  test "similar pending questions are flagged within the ticket group", %{conn: conn, request: r} do
    {:ok, second} = ask("Which delivery date should we use now?")
    {:ok, other} = ask("Which database engine?")
    {:ok, view, _} = live(conn, "/needs-you")
    # Decision 6: no per-ticket heading; the open card's header names the ticket.
    refute has_element?(view, "[data-ticket-heading]")
    assert has_element?(view, "#request-#{r.id} .bb-qhead-title", "Delivery")
    assert has_element?(view, "#duplicate-#{r.id}", "Similar question")
    render_patch(view, "/needs-you?card=#{second.id}")
    assert has_element?(view, "#duplicate-#{second.id}")
    render_patch(view, "/needs-you?card=#{other.id}")
    refute has_element?(view, "#duplicate-#{other.id}")
    render_patch(view, "/needs-you?card=#{r.id}")
    {:ok, _} = Requests.resolve(second.id, :answer, %{"answer" => "Friday"})
    send(view.pid, :reconcile)
    refute has_element?(view, "#duplicate-#{r.id}")
  end
end
