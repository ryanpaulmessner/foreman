defmodule ForemanWeb.BatchLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.Requests

  test "batch checkboxes submit a subset or none and show a readable outcome", %{conn: conn} do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Sweep", issue_type: "task", status: "open"})
    )

    for selected <- [["b"], []] do
      {:ok, r} =
        Requests.ask({"sample", "s-1"}, "batch", %{
          "facts" => %{
            "question" => "File tickets?",
            "text" => "What: Findings\nPart of: Sweep\nWhy now: Ready",
            "items" => [
              %{"id" => "a", "label" => "First"},
              %{"id" => "b", "label" => "Second", "detail" => "Fix timeout"}
            ]
          }
        })

      {:ok, view, _} = live(conn, "/needs-you")
      assert has_element?(view, "#batch-#{r.id} input[type=checkbox][value=a]")
      assert has_element?(view, "#batch-#{r.id} input[type=checkbox][value=b]")
      assert has_element?(view, "#batch-#{r.id}", "Fix timeout")
      assert has_element?(view, "#card-wrong-question-#{r.id}", "Wrong question")
      view |> form("#batch-#{r.id}", batch: %{items: selected}) |> render_submit()
      assert Requests.get(r.id).outcome == %{"answer" => selected}
      refute has_element?(view, "#request-#{r.id}")

      assert has_element?(
               view,
               "#recent-requests",
               if(selected == [], do: "None selected", else: "Second")
             )
    end
  end
end
