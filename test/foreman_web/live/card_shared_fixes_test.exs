defmodule ForemanWeb.CardSharedFixesTest do
  @moduledoc "Question cards shared fixes (fm-zgd.17.1) on Needs you and the drawer."
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.{Requests, ScratchDocs}

  @worktree "/srv/dev/foreman-worktrees/question-cards-shared-fixes/nested"

  setup do
    root = ScratchDocs.write(ScratchDocs.dir("shared-fixes"), %{"docs/spec.md" => "# Spec"})
    on_exit(fn -> File.rm_rf!(root) end)
    ScratchDocs.configure(%{"sample" => root})

    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "A ticket", issue_type: "task", status: "open"})
    )

    Foreman.Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])
    :ok
  end

  defp decision(actor, question) do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => actor,
        "facts" => Foreman.DecisionFacts.valid(%{"question" => question})
      })

    request
  end

  defp push do
    Foreman.Repo.insert!(%Foreman.Requests.Request{
      repo_key: "sample",
      bead_id: "s-1",
      kind: "push",
      actor: "pi",
      state: "pending",
      facts: %{
        "remote" => "owner/repo",
        "remote_branch" => "feat/question-cards",
        "local_branch" => "feat/question-cards",
        "expected_sha" => String.duplicate("a", 40),
        "worktree" => @worktree
      }
    })
  end

  defp text(view, selector),
    do: view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()

  test "a long worktree path breaks after each slash, with no break-all on the card", %{
    conn: conn
  } do
    request = push()
    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")

    for prefix <- ["", "drawer-"] do
      html = view |> element("##{prefix}push-worktree-#{request.id}") |> render()
      assert html =~ "bb-path"
      assert html =~ ~r{<span class="bb-path-part">dev/</span><wbr/?>}
      assert text(view, "##{prefix}push-worktree-#{request.id}") =~ @worktree
      assert has_element?(view, "##{prefix}push-destination-#{request.id}.bb-path")
    end

    refute view |> element("#pending-requests") |> render() =~ "break-all"
    refute view |> element("#request-drawer") |> render() =~ "break-all"
  end

  test "cards have no Always box and an answer from a card is not a standing answer", %{
    conn: conn
  } do
    request = decision("pi", "Which layout?")
    {:ok, view, _} = live(conn, "/needs-you")
    refute has_element?(view, "#always-#{request.id}")
    refute has_element?(view, "#decision-#{request.id} .bb-check")

    view
    |> form("#decision-#{request.id}", decision: %{note: "Friday"})
    |> render_submit(%{"action" => "answer"})

    assert Requests.get(request.id).state == "answered"
    assert Foreman.Answers.standing() == []
  end

  test "no actor word is a label on a card", %{conn: conn} do
    requests =
      for actor <- ["user", "claude", "pi"],
          do: decision(actor, "Which layout for #{String.length(actor)}?")

    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")

    for prefix <- ["", "drawer-"], request <- requests do
      card = text(view, "##{prefix}request-#{request.id}")
      refute card =~ ~r/\b(user|claude|pi)\b/i, "#{prefix}#{request.actor}: #{card}"
    end
  end

  test "a failed card action shows an error flash in the error line style", %{conn: conn} do
    request = decision("pi", "Which layout?")
    {:ok, view, _} = live(conn, "/needs-you")

    render_click(view, "resolve", %{"id" => request.id, "action" => "nope"})

    assert has_element?(view, "#flash-error.bb-status-error[role=alert]", "Request not updated")
    assert has_element?(view, "#flash-error .hero-exclamation-triangle")
  end

  describe "ticket and document panel" do
    setup %{conn: conn} do
      request = decision("pi", "Which layout?")
      %{request: request, conn: conn}
    end

    defp panel_count(view),
      do:
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#card-panel, [id$='card-panel']")
        |> Enum.count()

    test "one panel element opens as a sheet over a scrim, and the scrim closes it", %{
      conn: conn,
      request: request
    } do
      {:ok, view, _} = live(conn, "/needs-you?ticket=sample%3As-1")
      assert has_element?(view, "#card-panel.bb-sheet #ticket-title", "A ticket")
      assert has_element?(view, "#card-panel-scrim.bb-scrim")
      assert panel_count(view) == 1

      view |> element("#card-panel-scrim") |> render_click()
      # The open card stays in the URL next to the panel (Decision 7).
      assert_patch(view, "/needs-you?card=#{request.id}")
      refute has_element?(view, "#card-panel")
      refute has_element?(view, "#card-panel-scrim")
    end

    test "Esc closes the document panel", %{conn: conn, request: request} do
      {:ok, view, _} =
        live(conn, "/needs-you?" <> URI.encode_query(%{"doc" => "sample:docs/spec.md"}))

      assert has_element?(view, "#card-panel.bb-sheet #panel-document h1", "Spec")
      assert panel_count(view) == 1
      view |> element("#card-panel") |> render_keydown(%{"key" => "Escape"})
      assert_patch(view, "/needs-you?card=#{request.id}")
      refute has_element?(view, "#card-panel")
    end

    test "the X closes the ticket panel", %{conn: conn, request: request} do
      {:ok, view, _} = live(conn, "/needs-you?ticket=sample%3As-1")
      view |> element("#card-panel #ticket-close") |> render_click()
      assert_patch(view, "/needs-you?card=#{request.id}")
      refute has_element?(view, "#card-panel")
    end
  end
end
