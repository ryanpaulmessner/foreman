defmodule Foreman.Week.ModelTest do
  use ExUnit.Case, async: true
  alias Foreman.Week.Model

  defp ticket(id, attrs \\ %{}) do
    Map.merge(
      %{
        key: {"work", id},
        repo: "work",
        id: id,
        title: id,
        type: "task",
        kind: nil,
        edges: [],
        status: "open",
        stage: "queued",
        raw: %{},
        prs: []
      },
      attrs
    )
  end

  defp items(model) do
    for section <- model.sections, group <- section.groups, item <- group.items, do: item
  end

  test "activity sources include only the local week and configured repos" do
    tickets =
      for id <- ~w(stage request event note closed parked old boundary future other),
          do: ticket(id)

    tickets =
      Enum.map(tickets, fn t ->
        raw =
          case t.id do
            "note" -> %{"notes" => "- 2026-10-20 (pi): built it\n- 2026-10-25: checked"}
            "closed" -> %{"closed_at" => "2026-10-19T00:00:00Z"}
            "parked" -> %{"parked" => "2026-10-25"}
            "old" -> %{"notes" => "- 2026-10-18: old"}
            _ -> %{}
          end

        if t.id == "other",
          do: %{t | repo: "foreman", key: {"foreman", t.id}},
          else: %{t | raw: raw}
      end)

    events =
      for {id, time} <- [
            {"stage", ~U[2026-10-20 12:00:00Z]},
            {"event", ~U[2026-10-21 12:00:00Z]},
            {"boundary", ~U[2026-10-19 03:00:00Z]},
            {"future", ~U[2026-10-26 05:00:00Z]}
          ],
          do: %{key: {"work", id}, inserted_at: time}

    requests = [
      %{
        key: {"work", "request"},
        inserted_at: ~U[2026-10-20 12:00:00Z],
        state: "done",
        kind: "push",
        id: "r"
      }
    ]

    model =
      Model.build(
        %{tickets: tickets, events: events, requests: requests},
        ~U[2026-10-21 12:00:00Z]
      )

    assert model |> items() |> Enum.map(& &1.id) |> Enum.sort() ==
             ~w(closed event note parked request stage)
  end

  test "plain stages use the first matching rule" do
    cases =
      [
        {%{status: "closed"}, [], "Done"},
        {%{status: "closed", stage: "abandoned"}, [], "Done"},
        {%{stage: "abandoned"}, [], "Closed, not done"},
        {%{}, [%{kind: "decision", state: "pending", id: "r"}], "Waiting on you"},
        {%{status: "parked", stage: "building"}, [], "Waiting on others"},
        {%{prs: [%{"state" => "open"}], stage: "building"}, [], "Waiting on others"},
        {%{prs: [%{"state" => "merged"}], stage: "building"}, [], "Building"},
        {%{status: "closed", prs: [%{"state" => "merged"}]}, [], "Not started"},
        {%{}, [], "Not started"}
      ] ++
        for(
          reason <- ["won't do: no", "duplicate of x", "superseded by x", "out of scope now"],
          do: {%{status: "closed", raw: %{"close_reason" => reason}}, [], "Closed, not done"}
        ) ++
        for(
          stage <- ~w(dispatched building reported in_review committed),
          do: {%{stage: stage}, [], "Building"}
        ) ++
        for kind <- ~w(push open_pr merge decision session_waiting),
            do:
              {%{status: "parked"}, [%{kind: kind, state: "pending", id: "r"}], "Waiting on you"}

    for {attrs, requests, expected} <- cases do
      t = ticket("a", attrs)

      requests =
        Enum.map(requests, &Map.merge(&1, %{key: t.key, inserted_at: ~U[2026-10-20 12:00:00Z]}))

      [item] =
        Model.build(
          %{
            tickets: [t],
            requests: requests,
            events: [%{key: t.key, inserted_at: ~U[2026-10-20 12:00:00Z]}]
          },
          ~U[2026-10-21 12:00:00Z]
        )
        |> items()

      assert Map.get(item, :plain_stage) == expected, inspect({attrs, requests})
    end
  end

  test "sections follow kind order, inherit epic kinds and omit empty groups" do
    epic = ticket("epic", %{type: "epic", kind: "feature", title: "Better reports"})
    child = ticket("child", %{edges: [%{target: epic.key, type: "parent-child"}]})

    tickets =
      [epic, child] ++
        for kind <- ~w(break_fix mapping access internal unsorted),
            do: ticket(kind, %{kind: kind})

    events = for t <- tl(tickets), do: %{key: t.key, inserted_at: ~U[2026-10-20 12:00:00Z]}
    model = Model.build(%{tickets: tickets, events: events}, ~U[2026-10-21 12:00:00Z])

    assert Enum.map(model.sections, &Map.get(&1, :kind)) ==
             ~w(feature break_fix mapping access internal unsorted)

    assert hd(model.sections).groups |> Enum.map(& &1.epic_title) == ["Better reports"]
    assert Model.build(%{tickets: tickets}, ~U[2026-10-21 12:00:00Z]).sections == []
  end

  test "feature grouping uses the nearest epic" do
    far = ticket("a-far", %{type: "epic", kind: "feature", title: "Far"})
    middle = ticket("a-middle", %{edges: [%{target: far.key, type: "parent-child"}]})
    near = ticket("z-near", %{type: "epic", kind: "feature", title: "Near"})

    child =
      ticket("child", %{
        edges: [
          %{target: middle.key, type: "parent-child"},
          %{target: near.key, type: "parent-child"}
        ]
      })

    model =
      Model.build(
        %{
          tickets: [far, middle, near, child],
          events: [%{key: child.key, inserted_at: ~U[2026-10-20 12:00:00Z]}]
        },
        ~U[2026-10-21 12:00:00Z]
      )

    assert hd(hd(model.sections).groups).epic_title == "Near"
  end

  test "weeks start at local Monday midnight, including Sunday UTC crossover and DST" do
    for {now, first, last} <- [
          {~U[2026-10-19 03:00:00Z], ~U[2026-10-12 05:00:00Z], ~U[2026-10-19 05:00:00Z]},
          {~U[2026-10-21 12:00:00Z], ~U[2026-10-19 05:00:00Z], ~U[2026-10-26 05:00:00Z]},
          {~U[2026-03-08 12:00:00Z], ~U[2026-03-02 06:00:00Z], ~U[2026-03-09 05:00:00Z]},
          {~U[2026-11-01 12:00:00Z], ~U[2026-10-26 05:00:00Z], ~U[2026-11-02 06:00:00Z]}
        ] do
      assert %{start_at: ^first, end_at: ^last} = Model.window(now, "America/Chicago")
    end
  end
end
