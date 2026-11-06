defmodule Foreman.SessionFallbackTest do
  use Foreman.DataCase, async: false
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, SessionFallback, Repo}

  test "Claude family limits survive hooks and validation; shared and unclassified limits have no fallback" do
    row =
      agent_session(
        name: "claude",
        harness: "claude",
        kind: "epic_coordinator",
        model: "claude-opus-5-5",
        conversation_id: Ecto.UUID.generate()
      )

    {:ok, row, _} = AgentSessions.fire(row, :usage_limit)

    for {text, expected} <- [
          {"You've hit your Opus limit; resets 18:00", "claude-sonnet-5-5"},
          {"You've hit your weekly limit", nil},
          {"Usage limit on Opus", nil},
          {"You've hit your Opus limit and your session limit", nil}
        ] do
      {:waiting, facts} =
        Foreman.SessionHooks.facts("StopFailure", %{
          "error" => "rate_limit",
          "error_details" => text
        })

      {:ok, facts} = Foreman.SessionWaiting.validate(facts, nil)
      Repo.delete_all(Foreman.Requests.Request)

      Repo.insert!(%Foreman.Requests.Request{
        repo_key: "test",
        bead_id: "test",
        kind: "session_waiting",
        actor: "claude",
        state: "pending",
        agent_session_id: row.id,
        facts: facts
      })

      assert SessionFallback.model(row) == expected
    end
  end

  test "Pi usage limits use board pairs, not an arbitrary client model" do
    row = agent_session(model: "custom/primary")
    {:ok, row, _} = AgentSessions.fire(row, :usage_limit)

    Repo.insert_all(
      "board_config",
      [
        %{
          id: 1,
          source: "test",
          loaded_at: DateTime.utc_now(),
          config: %{
            "board" => %{
              "model_fallbacks" => [%{"from" => "custom/primary", "to" => "custom/backup"}]
            }
          }
        }
      ],
      on_conflict: {:replace, [:config]},
      conflict_target: [:id]
    )

    assert SessionFallback.model(row) == "custom/backup"
    assert SessionFallback.model(%{row | model: "unpaired"}) == nil
    assert SessionFallback.model(%{row | state: "working"}) == nil
    assert SessionFallback.model(%{row | kind: "epic_coordinator"}) == nil
  end
end
