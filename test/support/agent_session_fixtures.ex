defmodule Foreman.AgentSessionFixtures do
  @moduledoc "Identity rows for tests: a live session, and a request pointed at one."

  def agent_session(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "build",
          kind: "build",
          harness: "pi",
          tmux_server: "default",
          started_at: DateTime.add(DateTime.utc_now(), -60)
        },
        Map.new(attrs)
      )
      |> Map.new(fn
        {key, %DateTime{microsecond: {us, _}} = at} -> {key, %{at | microsecond: {us, 6}}}
        pair -> pair
      end)

    {:ok, row} = Foreman.AgentSessions.create(attrs)
    row
  end

  @doc "Points `request` at `session`, as an accepted ask from that session would."
  def asked_by(request, session),
    do:
      request
      |> Ecto.Changeset.change(agent_session_id: session.id)
      |> Foreman.Repo.update!()
end
