defmodule Foreman.SessionRegistry do
  @moduledoc "Named external sessions, independent of the ticket that a session asks about."
  import Ecto.Query
  alias Foreman.Repo

  def reconcile(opts \\ []) do
    rows =
      Repo.all(
        from s in "sessions",
          where: is_nil(s.ended_at),
          select: %{id: s.id, window: s.window, last_seen_at: s.last_seen_at}
      )

    with {:ok, panes} <- Foreman.SessionTargets.list(opts) do
      for row <- rows, not Foreman.SessionTargets.present?(panes, row.window) do
        {:ended, [save: :ended_at]} = Foreman.ExternalSession.step(:running, :pane_gone, %{})

        Repo.update_all(
          from(s in "sessions",
            where:
              s.id == ^row.id and s.window == ^row.window and s.last_seen_at == ^row.last_seen_at and
                is_nil(s.ended_at)
          ),
          set: [ended_at: DateTime.utc_now()]
        )
      end

      :ok
    end
  end

  def valid?(attrs) do
    text?(attrs["name"]) and text?(attrs["pane"]) and
      Regex.match?(~r/\A%\d+\z/, attrs["pane"]) and
      text?(attrs["workdir"]) and Path.type(attrs["workdir"]) == :absolute and
      attrs["harness"] in ["claude", "pi"]
  end

  def register(attrs) do
    if valid?(attrs) do
      Repo.transaction(fn ->
        name = attrs["name"]

        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "foreman:session:" <> name
        ])

        query =
          from s in "sessions",
            where:
              s.repo_key == "__foreman__" and s.bead_id == "registered" and
                fragment("?->>'session'", s.details) == ^name

        now = DateTime.utc_now()

        fields = %{
          window: attrs["pane"],
          details: %{
            "session" => name,
            "harness" => attrs["harness"],
            "workdir" => attrs["workdir"]
          },
          last_seen_at: now,
          ended_at: nil
        }

        existing = Repo.one(from s in query, select: %{id: s.id, ended_at: s.ended_at})
        state = if existing && existing.ended_at, do: :ended, else: :running
        {:running, [save: :registration]} = Foreman.ExternalSession.step(state, :register, %{})

        case existing do
          nil ->
            Repo.insert_all("sessions", [
              Map.merge(fields, %{repo_key: "__foreman__", bead_id: "registered", started_at: now})
            ])

          _ ->
            Repo.update_all(query, set: Map.to_list(fields))
        end

        %{name: name, pane: attrs["pane"]}
      end)
    else
      {:error, :invalid_session}
    end
  end

  defp text?(value),
    do:
      is_binary(value) and String.trim(value) != "" and byte_size(value) <= 4096 and
        not String.contains?(value, <<0>>)
end
