defmodule ForemanWeb.PullRequestsHumanMergeTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @remote "owner/report-scratch"

  setup do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    repo = %{
      "key" => "work",
      "path" => "/tmp/work",
      "enabled" => true,
      "tickets" => "files",
      "forge" => "github",
      "github" => @remote,
      "merge_policy" => "human",
      "merge_base" => "staging"
    }

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: Map.put(config, "repos", [repo]),
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    Foreman.Overlay.backfill(
      "work",
      for(
        id <- ~w(work-aaa work-bbb work-ccc work-ddd),
        do: %{bead_id: id, status: "open", issue_type: "task"}
      )
    )

    publish("open.json", [])
    :ok
  end

  defp publish(fixture, tracked) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(
        conn,
        Jason.decode!(File.read!("test/fixtures/forge/human-merge/" <> fixture))
      )
    end)

    {:ok, snapshot} =
      Foreman.Forge.GitHub.list(@remote,
        token: "test",
        tracked: tracked,
        plug: {Req.Test, __MODULE__}
      )

    Foreman.Forge.Store.replace("work", @remote, snapshot)
  end

  defp order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#pull-requests article")
    |> LazyHTML.attribute("data-number")
  end

  test "lists the stacks on the configured base with no merge control", %{conn: conn} do
    {:ok, view, _} = live(conn, "/pull-requests?project=work")
    assert has_element?(view, "#forge-panel", "Stack on staging")
    assert order(view) == ~w(11 12 14 13)
    assert has_element?(view, "#cr-work-12 [data-parent='11']")
    assert has_element?(view, "#cr-work-14 [data-parent='12']")

    for n <- [11, 12, 13, 14] do
      refute has_element?(view, "#merge-request-#{n}")

      assert has_element?(
               view,
               "#human-merge-#{n} [data-role=waiting]",
               "Waiting for a person to merge on GitHub"
             )

      assert has_element?(
               view,
               "#pr-link-#{n}[href='https://github.com/#{@remote}/pull/#{n}']"
             )
    end

    refute has_element?(view, "button", "Merge")
  end

  test "a forged merge event opens no confirmation and records nothing", %{conn: conn} do
    {:ok, view, _} = live(conn, "/pull-requests?project=work")
    render_click(view, "merge-request", %{"number" => "11"})
    refute has_element?(view, "#merge-confirm[data-open=true]")
    assert has_element?(view, "#merge-status", "Merge unavailable")
    assert Foreman.Repo.aggregate(Foreman.Merge.Record, :count) == 0
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 0
  end

  test "after a person merges the parent, the child shows the manual retarget step", %{
    conn: conn
  } do
    publish("merged-commit.json", [11, 12, 13, 14])
    {:ok, view, _} = live(conn, "/pull-requests?project=work")
    refute has_element?(view, "#cr-work-11")

    assert has_element?(
             view,
             "#human-merge-12 [data-role=manual-retarget]",
             "Retarget onto staging on GitHub"
           )

    assert has_element?(view, "#cr-work-14 [data-parent='12']")
    assert has_element?(view, "#human-merge-14 [data-role=waiting]")
    refute has_element?(view, "#human-merge-14 [data-role=manual-retarget]")
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 0
  end
end
