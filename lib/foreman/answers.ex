defmodule Foreman.Answers do
  @moduledoc "Saved answers and their append-only versions."
  import Ecto.Query
  alias Foreman.Repo
  alias Foreman.Answers.{Answer, Version}

  def create(attrs) do
    with {:ok, version} <-
           Version.changeset(%Version{}, attrs) |> Ecto.Changeset.apply_action(:insert) do
      Repo.transaction(fn ->
        answer = Repo.insert!(%Answer{})
        Repo.insert!(%{version | answer_id: answer.id})
        get(answer.id)
      end)
    end
  end

  def update(id, attrs) do
    with_locked(id, fn answer ->
      previous = hd(preload(answer).versions)
      inherited = Map.take(Map.from_struct(previous), [:question, :body, :repo, :ticket, :links])
      inherited = Map.new(inherited, fn {key, value} -> {to_string(key), value} end)

      case Repo.insert(Version.changeset(%Version{answer_id: id}, Map.merge(inherited, attrs))) do
        {:ok, _} -> get(id)
        {:error, changeset} -> {:error, changeset}
      end
    end)
  end

  defp with_locked(id, fun) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.transaction(fn ->
          case Repo.one(from a in Answer, where: a.id == ^id, lock: "FOR UPDATE") do
            nil -> {:error, :not_found}
            answer -> fun.(answer)
          end
        end)
        |> case do
          {:ok, {:error, reason}} -> {:error, reason}
          result -> result
        end

      _ ->
        {:error, :not_found}
    end
  end

  def change_state(id, event) when event in [:pin, :unpin, :archive, :restore] do
    with_locked(id, fn answer ->
      {state, []} = Foreman.Answers.State.step(answer.state, event, %{})
      answer |> Ecto.Changeset.change(state: state) |> Repo.update!() |> preload()
    end)
  end

  def list(filters \\ %{}) do
    latest = from v in Version, distinct: v.answer_id, order_by: [asc: v.answer_id, desc: v.id]

    query =
      from a in Answer,
        join: v in subquery(latest),
        on: v.answer_id == a.id,
        order_by: [desc: fragment("? IN ('pinned', 'archived_pinned')", a.state), desc: v.id],
        select: a

    query =
      if filters["archived"] == "true",
        do: query,
        else: where(query, [a], a.state in [:normal, :pinned])

    query =
      Enum.reduce(["repo", "ticket"], query, fn key, query ->
        case filters[key] do
          value when is_binary(value) and value != "" ->
            field_name = if key == "repo", do: :repo, else: :ticket
            where(query, [a, v], field(v, ^field_name) == ^value)

          _ ->
            query
        end
      end)

    query =
      case filters["search"] do
        value when is_binary(value) and value != "" ->
          where(
            query,
            [a, v],
            fragment("strpos(lower(? || ' ' || ?), lower(?)) > 0", v.question, v.body, ^value)
          )

        _ ->
          query
      end

    query |> Repo.all() |> Repo.preload(versions: from(v in Version, order_by: [desc: v.id]))
  end

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Answer, id) |> preload()
      _ -> nil
    end
  end

  defp preload(nil), do: nil

  defp preload(answer),
    do: Repo.preload(answer, versions: from(v in Version, order_by: [desc: v.id]))
end
