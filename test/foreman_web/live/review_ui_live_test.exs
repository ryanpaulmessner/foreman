defmodule ForemanWeb.ReviewUILiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

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
