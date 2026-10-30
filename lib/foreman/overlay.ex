defmodule Foreman.Overlay do
  @moduledoc """
  Authoritative workflow facts keyed by `{repo_key, bead_id}`, never cache IDs.

  `apply_event/3` accepts an atom or `{atom, payload}` and actor metadata. Event
  source is taken from the machine, not caller input. Invalid claims commit an
  audit row and return `{:error, %{stage: stage, allowed: events}}`.
  Notifications use transactional PostgreSQL NOTIFY: delivery occurs only after
  the outermost transaction commits (including projection reconciliation).
  """
  import Ecto.Query
  alias Foreman.{Repo, Stage, Epic}

  @fields [:id, :repo_key, :bead_id, :stage, :stage_changed_at, :lock_version, :orphaned_at]
  @event_fields [
    :id,
    :event,
    :source,
    :actor,
    :from_stage,
    :to_stage,
    :outcome,
    :payload,
    :effects,
    :inserted_at
  ]

  @doc "Whether this exact document path was recorded for the project."
  def document_reference?(repo, path) when is_binary(path) do
    fields = ~w(brief brief_path report report_path path spec spec_path spec_link design_link)

    predicate =
      Enum.reduce(fields, dynamic(false), fn field, query ->
        dynamic([e], ^query or fragment("? ->> ? = ?", e.payload, ^field, ^path))
      end)

    Repo.exists?(from e in "stage_events", where: e.repo_key == ^repo, where: ^predicate) or
      Repo.exists?(
        from e in "epics",
          where: e.repo_key == ^repo and (e.spec_link == ^path or e.design_link == ^path)
      )
  end

  def document_reference?(_, _), do: false

  def backfill(repo, beads) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Enum.each(beads, fn bead ->
          key = {repo, bead.bead_id}
          lock(key)
          machine = if bead.issue_type in [:epic, "epic"], do: Epic, else: Stage

          existing = get(key)

          if is_nil(existing) or existing.machine != machine do
            if existing do
              if existing.bead_id != bead.bead_id do
                apply_event({repo, existing.bead_id}, :bead_reclassified, %{actor: "backfill"})
              else
                Repo.delete_all(
                  from row in table(existing.machine), where: row.id == ^existing.id
                )
              end
            end

            stage =
              if bead.status in [:closed, "closed"],
                do: :done,
                else: if(machine == Epic, do: :ticketed, else: :queued)

            row = %{
              repo_key: repo,
              bead_id: bead.bead_id,
              stage: to_string(stage),
              stage_changed_at: DateTime.utc_now(),
              lock_version: 1
            }

            row = if machine == Epic, do: Map.put(row, :beads_epic_id, bead.bead_id), else: row
            Repo.insert_all(table(machine), [row])
            event = if existing, do: :reclassify, else: :backfill
            from_stage = if existing, do: existing.stage
            record(key, machine, event, %{}, "backfill", "beads", from_stage, stage, "row", [])
          end
        end)

        :ok
      end)

    :ok
  end

  def get({repo, id}) do
    epic =
      Repo.one(
        from e in "epics",
          where: e.repo_key == ^repo and (e.bead_id == ^id or e.beads_epic_id == ^id),
          select: map(e, ^(@fields ++ [:beads_epic_id, :title, :spec_link, :design_link]))
      )

    ticket =
      if is_nil(epic),
        do:
          Repo.one(
            from t in "tickets",
              where: t.repo_key == ^repo and t.bead_id == ^id,
              select: map(t, ^@fields)
          )

    case epic || ticket do
      nil ->
        nil

      row ->
        machine = if epic, do: Epic, else: Stage

        %{row | stage: Enum.find(machine.__fsm__(:states), &(to_string(&1) == row.stage))}
        |> Map.put(:machine, machine)
    end
  end

  def history(key) do
    {repo, id} = canonical(key)
    row = get(key)

    ids =
      if row && row.machine == Epic,
        do: Enum.reject([id, row.beads_epic_id], &is_nil/1),
        else: [id]

    Repo.all(
      from e in "stage_events",
        where: e.repo_key == ^repo and e.bead_id in ^ids,
        order_by: e.id,
        select: map(e, ^@event_fields)
    )
  end

  def apply_event(key, event, metadata \\ %{}) do
    case Repo.transaction(fn ->
           lock(key)
           key = canonical(key)
           maybe_create_draft(key, event)

           case get(key) do
             nil ->
               {:error, :not_found}

             row ->
               Repo.one(
                 from r in table(row.machine),
                   where: r.id == ^row.id,
                   lock: "FOR UPDATE",
                   select: r.id
               )

               {name, payload} =
                 case event do
                   {name, payload} when is_map(payload) -> {name, stringify(payload)}
                   name when is_atom(name) -> {name, %{}}
                 end

               data = data(key)

               guard_payload = %{
                 window: payload["window"],
                 number: payload["number"],
                 beads_epic_id: payload["beads_epic_id"]
               }

               source = Map.get(row.machine.__fsm__(:sources), name, :claimed) |> to_string()
               actor = Map.get(metadata, :actor, "user")
               result = row.machine.step(row.stage, {name, guard_payload}, data)

               case result do
                 {:error, _} ->
                   record(
                     key,
                     row.machine,
                     name,
                     payload,
                     source,
                     actor,
                     row.stage,
                     row.stage,
                     "invalid",
                     []
                   )

                   notify(key)
                   {:error, %{stage: row.stage, allowed: allowed(row, data)}}

                 {stage, effects} ->
                   validate_effects!(effects, payload)
                   outcome = outcome(row, name, guard_payload, data)

                   event_id =
                     record(
                       key,
                       row.machine,
                       name,
                       payload,
                       source,
                       actor,
                       row.stage,
                       stage,
                       outcome,
                       effects
                     )

                   changes = [stage: to_string(stage), lock_version: row.lock_version + 1]

                   changes =
                     if stage != row.stage,
                       do: Keyword.put(changes, :stage_changed_at, DateTime.utc_now()),
                       else: changes

                   Repo.update_all(from(r in table(row.machine), where: r.id == ^row.id),
                     set: changes
                   )

                   Enum.each(effects, &effect(&1, key, row, event_id, payload, actor))
                   if stage in [:done, :abandoned], do: Foreman.Requests.supersede(key)
                   if Foreman.Previews.ended?(key, stage), do: Foreman.Previews.cleanup(key)
                   notify(key)
                   {:ok, %{stage: get(key).stage, effects: effects}}
               end
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp outcome(row, event, payload, data) do
    selected =
      Enum.find(row.machine.__fsm__(:choices)[{row.stage, event}], fn choice ->
        is_nil(choice.guard) or apply(row.machine, choice.guard, [data, payload]) == true
      end)

    if selected.kind == :ignore, do: "ignored", else: "row"
  end

  defp maybe_create_draft({repo, "draft:" <> slug} = key, {:create, payload})
       when byte_size(slug) > 0 and is_map(payload) do
    if is_nil(get(key)) do
      Repo.insert_all("epics", [
        %{
          repo_key: repo,
          bead_id: "draft:" <> slug,
          stage: "new_draft",
          stage_changed_at: DateTime.utc_now(),
          lock_version: 1
        }
      ])
    end
  end

  defp maybe_create_draft(_, _), do: :ok

  defp stringify(map), do: map |> Jason.encode!() |> Jason.decode!()
  defp notify({repo, id}), do: Foreman.Events.broadcast(:overlay_changed, repo <> "/" <> id)

  def allowed_events(key) do
    case get(key) do
      nil -> []
      row -> allowed(row, data(canonical(key)))
    end
  end

  defp allowed(row, data) do
    Enum.filter(row.machine.__fsm__(:events), fn event ->
      row.machine.__fsm__(:sources)[event] == :claimed and
        not match?(
          {:error, _},
          row.machine.step(
            row.stage,
            {event, %{window: (data.session_window || "") <> ":new", beads_epic_id: "<epic>"}},
            data
          )
        )
    end)
  end

  defp data({repo, id}) do
    window =
      Repo.one(
        from s in "sessions",
          where: s.repo_key == ^repo and s.bead_id == ^id,
          order_by: [desc: s.id],
          limit: 1,
          select: s.window
      )

    crs =
      Repo.all(
        from c in "overlay_cr_links",
          where: c.repo_key == ^repo and c.bead_id == ^id,
          select: c.number
      )

    %{session_window: window, open_crs: crs}
  end

  defp validate_effects!(effects, payload) do
    cond do
      {:record, :session} in effects and
          not (is_binary(payload["window"]) and payload["window"] != "") ->
        Repo.rollback(:window_required)

      Enum.any?(effects, &(&1 in [{:link, :cr}, {:unlink, :cr}])) and
          not (is_integer(payload["number"]) and payload["number"] > 0) ->
        Repo.rollback(:cr_number_required)

      true ->
        :ok
    end
  end

  defp effect({kind, name}, key, row, event_id, payload, actor) do
    # Every non-notification effect has a durable, replayable receipt, including
    # commits, merges, flags and suggestions used by later ticket/forge views.
    if kind != :emit do
      Repo.insert_all("overlay_effects", [
        %{event_id: event_id, kind: to_string(kind), name: to_string(name), payload: payload}
      ])
    end

    persist_effect({kind, name}, key, row, event_id, payload, actor)
  end

  defp persist_effect({:record, :session}, {repo, id}, _, _, payload, _) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(s in "sessions",
        where: s.repo_key == ^repo and s.bead_id == ^id and is_nil(s.ended_at)
      ),
      set: [ended_at: now]
    )

    Repo.insert_all("sessions", [
      %{
        repo_key: repo,
        bead_id: id,
        window: payload["window"],
        details: payload,
        started_at: now,
        last_seen_at: now
      }
    ])
  end

  defp persist_effect({kind, name}, {repo, id}, _, event_id, payload, actor)
       when kind == :append or (kind == :record and name == :report) do
    now = DateTime.utc_now()

    Repo.insert_all("agent_notes", [
      %{
        event_id: event_id,
        repo_key: repo,
        bead_id: id,
        actor: actor,
        kind: to_string(name),
        body: payload["body"] || payload["path"],
        inserted_at: now
      }
    ])

    Repo.update_all(
      from(s in "sessions",
        where: s.repo_key == ^repo and s.bead_id == ^id and is_nil(s.ended_at)
      ),
      set: [last_seen_at: now]
    )
  end

  defp persist_effect({:link, :cr}, {repo, id}, _, _, payload, _) do
    Repo.insert_all(
      "overlay_cr_links",
      [%{repo_key: repo, bead_id: id, number: payload["number"]}],
      on_conflict: :nothing
    )
  end

  defp persist_effect({:unlink, :cr}, {repo, id}, _, _, payload, _) do
    Repo.delete_all(
      from c in "overlay_cr_links",
        where: c.repo_key == ^repo and c.bead_id == ^id and c.number == ^payload["number"]
    )
  end

  defp persist_effect({:record, :draft}, _, row, _, payload, _) do
    if not is_binary(payload["title"]) or String.trim(payload["title"]) == "",
      do: Repo.rollback(:title_required)

    Repo.update_all(from(e in "epics", where: e.id == ^row.id),
      set: [title: payload["title"], spec_link: payload["spec_link"]]
    )
  end

  defp persist_effect({:record, field}, _, row, _, payload, _)
       when field in [:spec_link, :design_link] do
    key = Atom.to_string(field)

    if Map.has_key?(payload, key) do
      Repo.update_all(from(e in "epics", where: e.id == ^row.id),
        set: [{field, payload[key]}]
      )
    end
  end

  defp persist_effect({:unlink, :beads_epic}, _, row, _, _, _) do
    Repo.update_all(from(e in "epics", where: e.id == ^row.id), set: [beads_epic_id: nil])
  end

  defp persist_effect({:link, :beads_epic}, {repo, id}, row, _, payload, _) do
    target = payload["beads_epic_id"]
    if String.starts_with?(target, "draft:"), do: Repo.rollback(:beads_epic_required)

    target_row = get({repo, target})

    case target_row do
      nil ->
        :ok

      %{machine: Epic, bead_id: ^target, id: target_id} ->
        Repo.delete_all(from e in "epics", where: e.id == ^target_id)

      _ ->
        Repo.rollback(:already_linked)
    end

    Repo.update_all(from(e in "epics", where: e.id == ^row.id), set: [beads_epic_id: target])

    if target_row && target_row.stage == :done do
      apply_event({repo, id}, :bead_epic_closed, %{actor: "beads"})
    end
  end

  defp persist_effect(_, _, _, _, _, _), do: :ok

  defp canonical(key) do
    case get(key) do
      nil -> key
      row -> {row.repo_key, row.bead_id}
    end
  end

  defp table(Epic), do: "epics"
  defp table(Stage), do: "tickets"

  defp lock({repo, _id}),
    do:
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "foreman:overlay:" <> repo
      ])

  defp record(
         {repo, id},
         machine,
         event,
         payload,
         source,
         actor,
         from_stage,
         to_stage,
         outcome,
         effects
       ) do
    {1, [row]} =
      Repo.insert_all(
        "stage_events",
        [
          %{
            repo_key: repo,
            bead_id: id,
            machine: inspect(machine),
            event: to_string(event),
            payload: payload,
            source: source,
            actor: actor,
            from_stage: from_stage && to_string(from_stage),
            to_stage: to_string(to_stage),
            outcome: outcome,
            effects: Enum.map(effects, fn {kind, name} -> %{kind: kind, name: name} end),
            inserted_at: DateTime.utc_now()
          }
        ],
        returning: [:id]
      )

    row.id
  end
end
