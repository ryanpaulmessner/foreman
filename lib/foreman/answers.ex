defmodule Foreman.Answers do
  @moduledoc "Saved answers and their append-only versions."
  import Ecto.Query
  alias Foreman.Repo
  alias Foreman.Answers.{Answer, Version}

  alias Foreman.Answers.StandingAnswer
  alias Foreman.Requests.Questions

  def standing_match(repo, facts) do
    key = standing_key(facts)
    answers = Repo.all(from a in StandingAnswer, where: a.repo_key == ^repo, order_by: a.id)
    exact = Enum.find(answers, &(&1.match_key == key))

    close =
      Enum.find(
        answers,
        &(option_set(%{"options" => &1.options}) == option_set(facts) and
            Questions.close?(&1.question, facts["question"]))
      )

    cond do
      exact -> {:exact, exact}
      close -> {:close, close}
      true -> :none
    end
  end

  def remember(request) do
    answer = %StandingAnswer{
      repo_key: request.repo_key,
      match_key: standing_key(request.facts),
      question: request.facts["question"],
      options: request.facts["options"] || [],
      answer: request.outcome["answer"],
      note: request.note
    }

    Repo.insert!(answer,
      on_conflict: {:replace, [:question, :options, :answer, :note, :updated_at]},
      conflict_target: [:repo_key, :match_key]
    )
  end

  def standing(filters \\ %{}) do
    query = from a in StandingAnswer, order_by: [desc: a.updated_at, asc: a.id]

    query =
      if filters["repo"] not in [nil, ""],
        do: where(query, [a], a.repo_key == ^filters["repo"]),
        else: query

    Repo.all(query)
  end

  def remove_standing(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %StandingAnswer{} = answer <- Repo.get(StandingAnswer, id) do
      Repo.transaction(fn ->
        Foreman.SessionWaiting.lock(answer.repo_key)
        Repo.delete_all(from a in StandingAnswer, where: a.id == ^id)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp option_set(facts),
    do: (facts["options"] || []) |> Enum.map(&Questions.normalize/1) |> Enum.uniq() |> Enum.sort()

  defp standing_key(facts),
    do:
      :crypto.hash(
        :sha256,
        Jason.encode!([Questions.normalize(facts["question"]), option_set(facts)])
      )
      |> Base.encode16(case: :lower)

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
