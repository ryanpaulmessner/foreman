defmodule ForemanWeb.AnswersLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "search, filters, pin, archive and restore", %{conn: conn} do
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
