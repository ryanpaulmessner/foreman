defmodule ForemanWeb.AnswersLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "tabs follow the URL and separate empty collections", %{conn: conn} do
    {:ok, view, _} = live(conn, "/answers")
    assert has_element?(view, "#answers-tab-saved[aria-current=page]", "Saved answers 0")
    assert has_element?(view, "#no-answers", "No saved answers yet.")
    assert has_element?(view, "#filters_archived")
    view |> element("#answers-tab-yours") |> render_click()
    assert_patch(view, "/answers?tab=yours")
    assert has_element?(view, "#no-answers", "You have not answered a card yet.")
    refute has_element?(view, "#filters_archived")
    view |> element("#answers-tab-rules") |> render_click()
    assert_patch(view, "/answers?tab=rules")
    assert has_element?(view, "#no-answers", "No Always rules.")
    refute has_element?(view, "#filters_archived")
    render_patch(view, "/answers?tab=invalid")
    assert has_element?(view, "#answers-tab-saved[aria-current=page]")
  end

  test "your answers show newest answered cards, notes and fifty more", %{conn: conn} do
    rows =
      for n <- 1..60 do
        Foreman.Repo.insert!(%Foreman.Requests.Request{
          repo_key: "sample",
          bead_id: "fm-#{n}",
          kind: Enum.at(["decision", "review_ui", "batch"], rem(n, 3)),
          actor: "user",
          session: "builder",
          state: "answered",
          facts: %{"question" => "Question #{n}"},
          outcome: %{"answer" => if(rem(n, 3) == 2, do: ["A", "B"], else: "Choice #{n}")},
          note: "Note #{n}",
          updated_at: DateTime.add(DateTime.utc_now(), n)
        })
      end

    ignored =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "fm-ignore",
        actor: "pi",
        kind: "decision",
        state: "declined",
        facts: %{"question" => "Not answered"}
      })

    {:ok, view, _} = live(conn, "/answers?tab=yours")
    assert has_element?(view, "#answers-tab-yours", "Your answers 60")
    assert has_element?(view, "#your-answers > article:first-child", "Question 60")
    assert has_element?(view, "#your-answer-#{List.last(rows).id}", "You answered Choice 60")
    assert has_element?(view, "#your-answer-#{List.last(rows).id}", "Note 60")
    assert has_element?(view, "#your-answer-#{List.last(rows).id}", "to builder")
    refute has_element?(view, "#your-answers .bb-answer-meta", "user")
    refute has_element?(view, "#your-answer-#{ignored.id}")
    refute has_element?(view, "#your-answer-#{hd(rows).id}")
    view |> element("#answers-more") |> render_click()
    assert has_element?(view, "#your-answer-#{hd(rows).id}")
    refute has_element?(view, "#answers-more")

    for search <- ["Question 60", "Choice 60", "Note 60"] do
      view |> form("#answer-filters", filters: %{search: search}) |> render_change()
      assert has_element?(view, "#your-answer-#{List.last(rows).id}")
      refute has_element?(view, "#your-answer-#{hd(rows).id}")
    end
  end

  test "batch answers use item labels in rows and search; session and ticket are links", %{
    conn: conn
  } do
    session = Foreman.AgentSessionFixtures.agent_session(name: "named-build")

    answer =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "fm-1",
        kind: "batch",
        actor: "user",
        session: session.name,
        agent_session_id: session.id,
        state: "answered",
        facts: %{
          "question" => "Pick checks",
          "items" => [
            %{"id" => "a", "label" => "Browser checks"},
            %{"id" => "b", "label" => "Unused check"}
          ]
        },
        outcome: %{"answer" => ["a"]}
      })

    {:ok, view, _} = live(conn, "/answers?tab=yours")
    assert has_element?(view, "#your-answer-#{answer.id}", "You answered Browser checks")

    assert has_element?(
             view,
             "#your-answer-#{answer.id} a[href='/sessions/#{session.id}']",
             "named-build"
           )

    assert has_element?(
             view,
             "#your-answer-#{answer.id}-ticket[href='/needs-you?ticket=sample%3Afm-1']"
           )

    view |> form("#answer-filters", filters: %{search: "Browser checks"}) |> render_change()
    assert has_element?(view, "#your-answer-#{answer.id}")
    view |> form("#answer-filters", filters: %{search: "Unused check"}) |> render_change()
    refute has_element?(view, "#your-answer-#{answer.id}")
  end

  test "loading has four skeletons and a load failure keeps filters for retry", %{conn: conn} do
    html = get(conn, "/answers") |> html_response(200) |> LazyHTML.from_document()
    assert html |> LazyHTML.query("#answers-loading [data-skeleton]") |> Enum.count() == 4
    {:ok, view, _} = live(conn, "/answers")

    Mimic.stub(Foreman.Answers, :list, fn _ ->
      raise DBConnection.ConnectionError, message: "offline"
    end)

    Mimic.allow(Foreman.Answers, self(), view.pid)
    view |> form("#answer-filters", filters: %{search: "kept"}) |> render_change()
    assert has_element?(view, "#answers-error", "Could not load answers.")
    assert has_element?(view, "#filters_search[value=kept]")
    Mimic.stub(Foreman.Answers, :list, fn _ -> [] end)
    view |> element("#answers-retry") |> render_click()
    refute has_element?(view, "#answers-error")
    assert has_element?(view, "#no-answers", "No answers match “kept”.")
  end

  test "no match on each tab keeps filters and can clear them", %{conn: conn} do
    for tab <- ~w(saved yours rules) do
      {:ok, view, _} = live(conn, "/answers?tab=#{tab}")
      view |> form("#answer-filters", filters: %{search: "absent"}) |> render_change()
      assert has_element?(view, "#no-answers", "No answers match “absent”.")
      view |> element("#answers-clear") |> render_click()
      refute has_element?(view, "#answers-clear")
      view |> form("#answer-filters", filters: %{ticket: "missing"}) |> render_change()
      assert has_element?(view, "#no-answers", "No answers match these filters.")
    end
  end

  test "rules search their question, answer and note and can be removed", %{conn: conn} do
    rule =
      Foreman.Repo.insert!(%Foreman.Answers.StandingAnswer{
        repo_key: "sample",
        match_key: "one",
        question: "Which tests?",
        options: [],
        answer: "All tests",
        note: "Before release"
      })

    {:ok, view, _} = live(conn, "/answers?tab=rules")
    assert has_element?(view, "#answers-tab-rules", "Always rules 1")

    for search <- ["Which", "All", "release"] do
      view |> form("#answer-filters", filters: %{search: search}) |> render_change()
      assert has_element?(view, "#always-rule-#{rule.id}")
    end

    view |> form("#answer-filters", filters: %{search: "absent"}) |> render_change()
    refute has_element?(view, "#always-rule-#{rule.id}")
    view |> element("#answers-clear") |> render_click()
    view |> element("#remove-standing-#{rule.id}") |> render_click()
    assert has_element?(view, "#answers-tab-rules", "Always rules 0")
    assert has_element?(view, "#no-answers", "No Always rules.")
  end

  test "removal failure keeps the rule and filters", %{conn: conn} do
    rule =
      Foreman.Repo.insert!(%Foreman.Answers.StandingAnswer{
        repo_key: "sample",
        match_key: "timeout",
        question: "Keep this rule?",
        options: [],
        answer: "Yes"
      })

    {:ok, view, _} = live(conn, "/answers?tab=rules")
    view |> form("#answer-filters", filters: %{search: "Keep"}) |> render_change()

    Mimic.stub(Foreman.Answers, :remove_standing, fn _ ->
      raise DBConnection.ConnectionError, message: "offline"
    end)

    Mimic.allow(Foreman.Answers, self(), view.pid)
    view |> element("#remove-standing-#{rule.id}") |> render_click()
    assert has_element?(view, "#always-rule-#{rule.id}")
    assert has_element?(view, "#filters_search[value=Keep]")
    assert has_element?(view, "#answer-change-error")
  end

  test "archive offers undo and a missing answer shows the error", %{conn: conn} do
    {:ok, answer} =
      Foreman.Answers.create(%{"question" => "Keep?", "body" => "Yes", "actor" => "user"})

    {:ok, view, _} = live(conn, "/answers")
    view |> element("#archive-#{answer.id}") |> render_click()
    assert has_element?(view, "#answer-archived", "Archived “Keep?”.")
    view |> element("#answer-undo") |> render_click()
    assert has_element?(view, "#answer-#{answer.id}")
    refute has_element?(view, "#answer-#{answer.id} .bb-answer-meta", "user")
    for version <- Foreman.Answers.get(answer.id).versions, do: Foreman.Repo.delete!(version)
    Foreman.Repo.delete!(Foreman.Answers.get(answer.id))
    view |> element("#pin-#{answer.id}") |> render_click()
    assert has_element?(view, "#answer-change-error", "Answer not changed.")
  end

  test "search, filters, pin, archive and restore", %{conn: conn} do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [
        %{"key" => "sample", "path" => System.tmp_dir!(), "enabled" => true}
      ])

    Foreman.Repo.insert_all("board_config", [
      %{id: 1, config: config, source: "test", discovered: [], loaded_at: DateTime.utc_now()}
    ])

    {:ok, answer} =
      Foreman.Answers.create(%{
        "question" => "What?",
        "body" => "Searchable",
        "actor" => "pi",
        "repo" => "sample",
        "ticket" => "fm-1"
      })

    {:ok, other} =
      Foreman.Answers.create(%{"question" => "Other", "body" => "Other", "actor" => "pi"})

    {:ok, view, _} = live(conn, "/answers")

    view
    |> form("#answer-filters", filters: %{search: "searchable", repo: "sample", ticket: "fm-1"})
    |> render_change()

    assert has_element?(view, "#answer-#{answer.id}")
    refute has_element?(view, "#answer-#{other.id}")
    view |> element("#pin-#{answer.id}") |> render_click()
    assert Foreman.Answers.get(answer.id).state == :pinned
    assert has_element?(view, "#pin-#{answer.id}", "Unpin")
    view |> element("#archive-#{answer.id}") |> render_click()
    refute has_element?(view, "#answer-#{answer.id}")

    view
    |> form("#answer-filters", filters: %{search: "", repo: "", ticket: "", archived: "true"})
    |> render_change()

    assert has_element?(view, "#archive-#{answer.id}", "Restore")
    view |> element("#archive-#{answer.id}") |> render_click()
    assert Foreman.Answers.get(answer.id).state == :pinned
    view |> element("#pin-#{answer.id}") |> render_click()
    assert Foreman.Answers.get(answer.id).state == :normal
  end

  test "a copied link opens an archived answer", %{conn: conn} do
    {:ok, answer} =
      Foreman.Answers.create(%{
        "question" => "Archived reference",
        "body" => "Still readable",
        "actor" => "pi"
      })

    {:ok, _} = Foreman.Answers.change_state(answer.id, :archive)
    {:ok, view, _} = live(conn, "/answers?id=#{answer.id}")
    assert has_element?(view, "#answer-body-#{answer.id}", "Still readable")
    assert has_element?(view, "#filters_archived[checked]")
  end

  test "links existing documents without a repo and refuses unsafe or missing links", %{
    conn: conn
  } do
    root = Path.join(System.tmp_dir!(), "answer-docs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "# Reference")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config = Map.put(config, "repos", [%{"key" => "sample", "path" => root, "enabled" => true}])

    Foreman.Repo.insert_all("board_config", [
      %{id: 1, config: config, source: "test", discovered: [], loaded_at: DateTime.utc_now()}
    ])

    {:ok, answer} =
      Foreman.Answers.create(%{
        "question" => "Docs?",
        "body" => "See README.md",
        "actor" => "pi",
        "links" => ["README.md", "missing.md", "javascript:alert(1)", "https://example.com"]
      })

    {:ok, view, _} = live(conn, "/answers?id=#{answer.id}")

    assert has_element?(
             view,
             "#answer-#{answer.id} ul a[href='/documents/sample?path=README.md']"
           )

    assert has_element?(
             view,
             "#answer-body-#{answer.id} a[href='/documents/sample?path=README.md']"
           )

    assert has_element?(view, "#answer-#{answer.id} a[href='https://example.com']")
    refute has_element?(view, "#answer-#{answer.id} a[href*=missing]")
    refute has_element?(view, "#answer-#{answer.id} a[href^='javascript:']")
  end

  test "Markdown links to missing documents are not active", %{conn: conn} do
    {:ok, answer} =
      Foreman.Answers.create(%{
        "question" => "Missing?",
        "body" => "[Missing](missing.md)",
        "actor" => "pi",
        "repo" => "sample"
      })

    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [
        %{"key" => "sample", "path" => System.tmp_dir!(), "enabled" => true}
      ])

    Foreman.Repo.insert_all("board_config", [
      %{id: 1, config: config, source: "test", discovered: [], loaded_at: DateTime.utc_now()}
    ])

    {:ok, view, _} = live(conn, "/answers?id=#{answer.id}")
    refute has_element?(view, "#answer-body-#{answer.id} a[href*=missing]")
  end

  test "list expands safe Markdown and earlier versions", %{conn: conn} do
    {:ok, answer} =
      Foreman.Answers.create(%{
        "question" => "Why?",
        "body" => "Old",
        "actor" => "pi",
        "links" => ["https://example.com/old"]
      })

    {:ok, _} =
      Foreman.Answers.update(answer.id, %{
        "body" => "**New**<script>alert(1)</script>",
        "actor" => "pi",
        "links" => []
      })

    {:ok, view, _} = live(conn, "/answers")
    assert has_element?(view, "#answers-link[aria-current=page]")
    assert has_element?(view, "#answer-#{answer.id}", "Why?")
    refute has_element?(view, "#answer-body-#{answer.id}")
    view |> element("#expand-#{answer.id}") |> render_click()
    assert has_element?(view, "#answer-body-#{answer.id} strong", "New")
    refute has_element?(view, "#answer-body-#{answer.id} script")
    assert has_element?(view, "#versions-#{answer.id}", "Earlier versions (1)")
    assert has_element?(view, "#versions-#{answer.id}", "Old")
    assert has_element?(view, "#versions-#{answer.id} a[href='https://example.com/old']")
  end
end
