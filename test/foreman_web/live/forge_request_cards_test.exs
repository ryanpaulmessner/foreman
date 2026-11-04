defmodule ForemanWeb.ForgeRequestCardsTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "approval cards name history replacement and the base override", %{conn: conn} do
    Foreman.Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])

    push =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        kind: "push",
        actor: "pi",
        state: "pending",
        facts: %{
          "remote" => "owner/repo",
          "remote_branch" => "feature",
          "local_branch" => "feature",
          "expected_sha" => String.duplicate("a", 40),
          "expected_old_head" => String.duplicate("b", 40),
          "force_with_lease" => true,
          "worktree" => "/tmp/fixture"
        }
      })

    pr =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        kind: "open_pr",
        actor: "pi",
        state: "pending",
        facts: %{
          "remote" => "owner/repo",
          "head_branch" => "feature",
          "base_branch" => "other",
          "base_ok" => true,
          "title" => "Update",
          "body" => "Details",
          "expected_sha" => String.duplicate("a", 40)
        }
      })

    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#force-push-#{push.id}", "Replace the branch history")
    # One card is open at a time (Decision 3).
    render_patch(view, "/needs-you?card=#{pr.id}")
    assert has_element?(view, "#base-override-#{pr.id}", "--base-ok")
  end
end
