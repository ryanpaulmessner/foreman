defmodule ForemanWeb.ReviewUILiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "try-it states show the walkthrough and restrict Works until up", %{conn: conn} do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Try the card", issue_type: "task", status: "open"})
    )

    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        actor: "pi",
        session: "builder",
        kind: "review_ui",
        state: "pending",
        facts: %{
          "question" => "Does it work?",
          "url" => "http://localhost:4812",
          "sha" => String.duplicate("a", 40),
          "walkthrough_path" => "/repo/walk.json",
          "walkthrough" => %{
            "intro" => "Try the new card.",
            "steps" => [%{"say" => "Open the preview", "see" => "A card"}]
          },
          "video" => "/repo/run.webm",
          "preview" => "unchecked",
          "options" => ["Works", "Found a problem"],
          "images" => []
        }
      })

    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#review-try-it-#{request.id}")
    assert has_element?(view, "#review-preview-#{request.id}[target='_blank']", "Open preview")
    assert has_element?(view, "#review-steps-#{request.id} li", "Open the preview")

    assert has_element?(
             view,
             "#review-video-#{request.id}[src='/request-images/#{request.id}/video']"
           )

    assert has_element?(view, "#option-#{request.id}-0[disabled]")
    refute has_element?(view, "#review-preview-state-#{request.id}")

    for state <- ["up", "down"] do
      request
      |> Ecto.Changeset.change(facts: Map.put(request.facts, "preview", state))
      |> Foreman.Repo.update!()

      send(
        view.pid,
        {:notification, :foreman_events,
         %{"version" => 1, "kind" => "requests_changed", "key" => request.id}}
      )

      if state == "up" do
        assert has_element?(view, "#option-#{request.id}-0:not([disabled])")
      else
        assert has_element?(
                 view,
                 "#review-preview-state-#{request.id}",
                 "The preview is not running. Ask builder to start it again."
               )

        assert has_element?(view, "#option-#{request.id}-0[disabled]")
        assert has_element?(view, "#option-#{request.id}-1:not([disabled])")
      end
    end

    view
    |> form("#decision-#{request.id}",
      decision: %{choice: "Found a problem", note: "The button clips"}
    )
    |> render_submit(%{"action" => "answer"})

    assert has_element?(view, "#recent-requests [data-tried-sha]", "aaaaaaa")
    assert has_element?(view, "#recent-requests", "Found a problem: The button clips")
  end

  test "answered Works shows its commit without answer controls", %{conn: conn} do
    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        actor: "pi",
        kind: "review_ui",
        state: "answered",
        facts: %{
          "question" => "Does it work?",
          "url" => "http://localhost:4812",
          "sha" => String.duplicate("b", 40),
          "preview" => "stopped"
        },
        outcome: %{"answer" => "Works"}
      })

    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#recent-requests [data-tried-sha]", "bbbbbbb")
    assert has_element?(view, "#recent-requests", "Works")
    refute has_element?(view, "#decision-#{request.id}")
  end

  test "review grid groups widths and themes and returns comments with the answer", %{conn: conn} do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Layout", issue_type: "task", status: "open"})
    )

    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        actor: "pi",
        kind: "review_ui",
        state: "pending",
        facts: %{
          "question" => "Check the layout?",
          "options" => ["Looks right", "Change it"],
          "artifact" => "https://example.com/review",
          "images" => [
            %{
              "path" => "/repo/desktop.png",
              "width" => 1440,
              "theme" => "light",
              "look_at" => "Header spacing"
            },
            %{"path" => "/repo/phone.png", "width" => 390, "theme" => "dark", "look_at" => "Menu"}
          ]
        }
      })

    {:ok, view, _} = live(conn, "/needs-you")

    assert has_element?(
             view,
             "#review-images-#{request.id} [data-width='1440'][data-theme='light']",
             "Header spacing"
           )

    assert has_element?(
             view,
             "#review-images-#{request.id} [data-width='390'][data-theme='dark']",
             "Menu"
           )

    assert has_element?(
             view,
             "#review-image-#{request.id}-0 a[href='/request-images/#{request.id}/0'] img"
           )

    assert has_element?(view, "#review-artifact-#{request.id}[href='https://example.com/review']")

    view
    |> form("#decision-#{request.id}",
      decision: %{
        choice: "Change it",
        note: "Keep the colors",
        image_comments: %{"0" => "Too tall", "1" => "Menu clips"}
      }
    )
    |> render_submit(%{"action" => "answer"})

    answered = Foreman.Requests.get(request.id)
    assert has_element?(view, "#recent-requests .fm-card-question", "Check the layout?")
    assert answered.outcome == %{"answer" => "Change it"}

    assert answered.note ==
             "Keep the colors\n/repo/desktop.png: Too tall\n/repo/phone.png: Menu clips"
  end
end
