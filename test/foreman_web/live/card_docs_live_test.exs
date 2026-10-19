defmodule ForemanWeb.CardDocsLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.{Requests, ScratchDocs}

  setup do
    root =
      ScratchDocs.write(ScratchDocs.dir("card-docs"), %{
        "README.md" => "# Project",
        "slices/one/reviews/27-r1.md" => "# Review 27\n\nLooks good.",
        "docs/spec.md" => "# Spec"
      })

    outside = ScratchDocs.write(ScratchDocs.dir("card-docs-outside"), %{"secret.md" => "# No"})
    on_exit(fn -> File.rm_rf!(root) && File.rm_rf!(outside) end)
    ScratchDocs.configure(%{"sample" => root})

    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{
        id: "s-1",
        title: "A ticket",
        issue_type: "task",
        status: "open",
        description: "Ticket body text"
      })
    )

    %{root: root, outside: outside}
  end

  defp decision(facts) do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{"actor" => "pi", "facts" => facts})

    request
  end

  defp doc_href(path), do: Foreman.Markdown.viewer_path("sample", path)

  test "decision question and text render as Markdown, never raw HTML", %{conn: conn} do
    request =
      decision(%{
        "question" => "First paragraph.\n\nWhich of these?\n- **Wide**\n- Compact",
        "text" => "Context `code` here.\n\n<script>alert(1)</script>",
        "options" => ["Wide", "Compact"]
      })

    {:ok, view, _} = live(conn, "/needs-you")
    question = "#question-#{request.id}"
    assert has_element?(view, "#{question} p", "First paragraph.")
    assert has_element?(view, "#{question} p", "Which of these?")
    assert has_element?(view, "#{question} li strong", "Wide")
    assert has_element?(view, "#text-#{request.id} code", "code")
    refute render(view) =~ "<script>alert"
    refute has_element?(view, "#question-#{request.id}-more")

    render_click(view, "open-request-drawer")
    assert has_element?(view, "#drawer-question-#{request.id} li", "Compact")
  end

  test "long text shows its first lines with Show more", %{conn: conn} do
    request = decision(%{"question" => Enum.map_join(1..12, "\n\n", &"Paragraph #{&1}")})
    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#question-#{request.id}.fm-clamp")
    assert has_element?(view, "#question-#{request.id}-more", "Show more")
  end

  test "detected paths link to existing documents only; missing and outside paths stay text",
       %{conn: conn, root: root, outside: outside} do
    request =
      decision(%{
        "question" => "Read slices/one/reviews/27-r1.md:4 first?",
        "text" => "Also #{root}/docs/spec.md, slices/one/reviews/99.md and #{outside}/secret.md"
      })

    {:ok, view, _} = live(conn, "/needs-you")
    card = "#request-#{request.id}"

    assert has_element?(
             view,
             "#{card} a[href='#{doc_href("slices/one/reviews/27-r1.md")}']",
             "slices/one/reviews/27-r1.md:4"
           )

    assert has_element?(view, "#{card} a[href='#{doc_href("docs/spec.md")}']")
    assert has_element?(view, "#{card} #text-#{request.id}", "slices/one/reviews/99.md")
    refute has_element?(view, "#{card} a[href*='99.md']")
    refute has_element?(view, "#{card} a[href*='secret']")
  end

  test "explicit --doc links show on the card, open in the side panel and in the viewer",
       %{conn: conn} do
    request = decision(%{"question" => "Ship it?", "docs" => ["slices/one/reviews/27-r1.md"]})
    href = doc_href("slices/one/reviews/27-r1.md")

    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#docs-#{request.id} a[href='#{href}']", "27-r1.md")
    refute has_element?(view, "#card-panel")

    render_hook(view, "open-doc", %{"href" => href})

    assert_patch(
      view,
      "/needs-you?" <> URI.encode_query(%{"doc" => "sample:slices/one/reviews/27-r1.md"})
    )

    assert has_element?(view, "#card-panel #panel-document h1", "Review 27")
    assert has_element?(view, "#card-panel a#panel-open-viewer[href='#{href}']")
    # The card stays on the page next to the panel.
    assert has_element?(view, "#request-#{request.id}")

    view |> element("#panel-close") |> render_click()
    assert_patch(view, "/needs-you")
    refute has_element?(view, "#card-panel")

    {:ok, viewer, _} = live(conn, href)
    assert has_element?(viewer, "#document-content h1", "Review 27")
  end

  test "the side panel refuses paths outside the repo", %{conn: conn, outside: outside} do
    {:ok, view, _} =
      live(
        conn,
        "/needs-you?" <> URI.encode_query(%{"doc" => "sample:" <> outside <> "/secret.md"})
      )

    assert has_element?(view, "#card-panel #panel-status", "Document unavailable")
    refute render(view) =~ "# No"

    {:ok, view, _} = live(conn, "/needs-you?doc=sample:../secret.md")
    assert has_element?(view, "#panel-status", "Document unavailable")
  end

  test "every card links its ticket, which opens in the same side panel", %{conn: conn} do
    request = decision(%{"question" => "Which?"})
    {:ok, view, _} = live(conn, "/needs-you")

    view |> element("#ticket-link-#{request.id}", "s-1") |> render_click()
    assert_patch(view, "/needs-you?ticket=sample%3As-1")
    assert has_element?(view, "#card-panel #ticket-title", "A ticket")
    assert has_element?(view, "#card-panel #ticket-overview", "Ticket body text")
    assert has_element?(view, "#request-#{request.id}")

    # Opening a document replaces the ticket in the panel.
    render_hook(view, "open-doc", %{"href" => doc_href("docs/spec.md")})
    assert has_element?(view, "#card-panel #panel-document h1", "Spec")
    refute has_element?(view, "#card-panel #ticket-title")

    render_click(view, "open-request-drawer")

    assert has_element?(
             view,
             "#drawer-ticket-link-#{request.id}[href='/needs-you?ticket=sample%3As-1']"
           )
  end

  test "chat-question and AskUserQuestion text render as Markdown with path links", %{conn: conn} do
    session =
      Foreman.Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "s-1",
        workdir: "/tmp",
        window: "@42",
        state: :running,
        launched_at: DateTime.utc_now()
      })

    {:ok, chat} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => session.session_id,
        "facts" => %{
          "reason" => "question",
          "question" => "Review is in docs/spec.md. Which next?\n\n- Commit now\n- Hold"
        }
      })

    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-2", title: "Other", issue_type: "task", status: "open"})
    )

    other =
      Foreman.Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "s-2",
        workdir: "/tmp",
        window: "@43",
        state: :running,
        launched_at: DateTime.utc_now()
      })

    {:ok, input} =
      Requests.ask({"sample", "s-2"}, "session_waiting", %{
        "session" => other.session_id,
        "facts" => %{
          "reason" => "input",
          "tool" => "q-1",
          "tool_name" => "AskUserQuestion",
          "questions" => [
            Map.put(Foreman.ScratchPrompt.question(), "question", "Per **docs/spec.md**, which?")
          ]
        }
      })

    {:ok, view, _} = live(conn, "/needs-you")

    assert has_element?(
             view,
             "#question-#{input.id} strong a[href='#{doc_href("docs/spec.md")}']"
           )

    assert has_element?(view, "#chat-question-#{chat.id} li", "Hold")
    assert has_element?(view, "#chat-question-#{chat.id} a[href='#{doc_href("docs/spec.md")}']")
    assert has_element?(view, "#ticket-link-#{chat.id}")
    assert has_element?(view, "#reply-#{chat.id}")
  end

  test "push and PR facts render the PR body as Markdown", %{conn: conn} do
    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        kind: "open_pr",
        actor: "pi",
        state: "pending",
        facts: %{
          "remote" => "owner/repo",
          "head_branch" => "feature",
          "base_branch" => "main",
          "expected_sha" => String.duplicate("a", 40),
          "title" => "Exact title",
          "body" => "## Summary\n\n- one\n- two\n\nSee docs/spec.md"
        }
      })

    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#pr-body-#{request.id} li", "two")
    assert has_element?(view, "#pr-body-#{request.id} a[href='#{doc_href("docs/spec.md")}']")
    assert has_element?(view, "#ticket-link-#{request.id}")
  end

  test "recent outcomes render the question as Markdown and link the ticket", %{conn: conn} do
    request = decision(%{"question" => "Pick one:\n\n- A\n- B", "docs" => ["docs/spec.md"]})
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "A"})

    {:ok, view, _} = live(conn, "/needs-you")
    card = "#recent-#{request.id}"
    assert has_element?(view, "#{card} li", "B")
    assert has_element?(view, "#{card} a[href='#{doc_href("docs/spec.md")}']")
    view |> element("#{card} #recent-#{request.id}-ticket-link") |> render_click()
    assert_patch(view, "/needs-you?ticket=sample%3As-1")

    # The same request in the panel's Requests tab keeps page ids unique.
    render_patch(view, "/needs-you?ticket=sample%3As-1&tab=requests")
    html = render(view)

    ids =
      LazyHTML.from_document(html) |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")

    assert ids -- Enum.uniq(ids) == []
  end

  test "a ticket that disappears while open closes the panel instead of crashing", %{conn: conn} do
    {:ok, view, _} = live(conn, "/needs-you?ticket=sample%3As-1")
    assert has_element?(view, "#card-panel #ticket-title")
    Foreman.Beads.Projection.replace("sample", "")
    Foreman.Repo.delete_all("tickets")
    send(view.pid, :reconcile)
    refute has_element?(view, "#card-panel")
  end
end
