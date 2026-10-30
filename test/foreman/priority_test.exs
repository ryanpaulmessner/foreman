defmodule Foreman.PriorityTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Overlay, Priority, Requests}
  alias Foreman.Beads.Projection

  defp project(rows),
    do: {:ok, _} = Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))

  defp b(id, priority, extra \\ %{}),
    do:
      Map.merge(
        %{id: id, title: "Title #{id}", issue_type: "task", status: "open", priority: priority},
        extra
      )

  describe "rank" do
    test "P0 sorts first and a missing or malformed priority sorts after P4" do
      assert Enum.sort_by([nil, 4, 0, "2", 2, 9], &Priority.rank/1) == [0, 2, 4, nil, "2", 9]
    end
  end

  describe "override machine" do
    alias Foreman.PriorityOverride, as: M

    test "a board value differing from the file is stored; the file's value clears it" do
      assert {:board, [store: :override]} = M.step(:file, {:set, %{priority: 0, file: 2}}, nil)
      assert {:file, []} = M.step(:file, {:set, %{priority: 2, file: 2}}, nil)
      assert {:board, [store: :override]} = M.step(:board, {:set, %{priority: 1, file: 2}}, nil)
      assert {:file, [clear: :override]} = M.step(:board, {:set, %{priority: 2, file: 2}}, nil)
    end

    test "a sync clears only when the file carries the board's value" do
      assert {:file, [clear: :override]} = M.step(:board, {:synced, %{priority: 1, file: 1}}, nil)
      assert {:board, []} = M.step(:board, {:synced, %{priority: 1, file: 3}}, nil)
      assert {:file, []} = M.step(:file, {:synced, %{priority: 1, file: 3}}, nil)
    end
  end

  describe "board override" do
    setup do
      project([b("a", 2)])
      :ok
    end

    test "wins over the file value and is marked changed on board" do
      assert {:ok, 0} = Priority.set({"sample", "a"}, 0, "user")

      assert %{{"sample", "a"} => %{priority: 0, file: 2, changed_on_board: true}} =
               Priority.for_keys([{"sample", "a"}])
    end

    test "setting the file's own value clears the override" do
      {:ok, 0} = Priority.set({"sample", "a"}, 0, "user")
      assert {:ok, 2} = Priority.set({"sample", "a"}, 2, "user")

      assert %{{"sample", "a"} => %{priority: 2, changed_on_board: false}} =
               Priority.for_keys([{"sample", "a"}])

      assert Priority.overrides() == []
    end

    test "a file sync carrying the same value clears it; a different value keeps it" do
      {:ok, 1} = Priority.set({"sample", "a"}, 1, "user")
      project([b("a", 3)])
      assert [%{repo: "sample", id: "a", priority: 1, file_priority: 3}] = Priority.overrides()
      project([b("a", 1)])
      assert Priority.overrides() == []
      project([b("a", 4)])

      assert %{{"sample", "a"} => %{priority: 4, changed_on_board: false}} =
               Priority.for_keys([{"sample", "a"}])
    end

    test "out-of-range values and unknown tickets are refused" do
      assert {:error, :invalid_priority} = Priority.set({"sample", "a"}, 5, "user")
      assert {:error, :invalid_priority} = Priority.set({"sample", "a"}, "0", "user")
      assert {:error, :not_found} = Priority.set({"sample", "missing"}, 0, "user")
      assert Priority.overrides() == []
    end
  end

  describe "jump to front" do
    setup do
      project([b("a", 3), b("b", 2)])
      :ok
    end

    test "sets P0 and records a board event the coordinator reads as a pending jump" do
      assert {:ok, 0} = Priority.jump({"sample", "a"}, "user")

      assert %{{"sample", "a"} => %{priority: 0, changed_on_board: true}} =
               Priority.for_keys([{"sample", "a"}])

      assert [%{event: "jump", actor: "user", source: "observed", to_stage: "queued"}] =
               Overlay.history({"sample", "a"}) |> Enum.filter(&(&1.event == "jump"))

      assert [%{repo: "sample", id: "a", actor: "user", at: %DateTime{}}] =
               Priority.pending_jumps()
    end

    test "pending jumps are newest first and leave once the ticket is dispatched" do
      {:ok, 0} = Priority.jump({"sample", "a"}, "user")
      {:ok, 0} = Priority.jump({"sample", "b"}, "user")
      assert Enum.map(Priority.pending_jumps(), & &1.id) == ["b", "a"]

      {:ok, _} = Overlay.apply_event({"sample", "b"}, {:dispatch, %{window: "w"}}, %{actor: "pi"})
      assert Enum.map(Priority.pending_jumps(), & &1.id) == ["a"]
    end

    test "foreman ls --overlay returns pending jumps and board overrides for the coordinator" do
      {:ok, 0} = Priority.jump({"sample", "a"}, "user")
      {:ok, 4} = Priority.set({"sample", "b"}, 4, "user")

      assert {200, body} = Foreman.AgentCommands.execute(%{"action" => "ls"})
      body = body |> Jason.encode!() |> Jason.decode!()
      assert [%{"repo" => "sample", "id" => "a", "actor" => "user", "at" => _}] = body["jumps"]

      assert Enum.map(
               body["priority_overrides"],
               &{&1["id"], &1["priority"], &1["file_priority"]}
             ) ==
               [{"b", 4, 2}, {"a", 0, 3}]

      assert length(body["items"]) == 2

      assert {200, %{jumps: [], priority_overrides: []}} =
               Foreman.AgentCommands.execute(%{"action" => "ls", "project" => "other"})
    end

    test "only queued tickets can jump" do
      {:ok, _} = Overlay.apply_event({"sample", "a"}, {:dispatch, %{window: "w"}}, %{actor: "pi"})
      assert {:error, :not_queued} = Priority.jump({"sample", "a"}, "user")
      assert Priority.overrides() == []
      assert Priority.pending_jumps() == []
    end
  end

  describe "Needs you order" do
    test "pending requests sort by their ticket's priority, then oldest first" do
      project([b("low", 3), b("high", 1), b("none", nil), b("high2", 1)])

      ask = fn id ->
        {:ok, request} =
          Requests.ask({"sample", id}, "decision", %{
            "facts" => Foreman.DecisionFacts.valid(%{"question" => "Go?"})
          })

        request
      end

      ids = Enum.map(~w(low none high high2), &ask.(&1).bead_id)
      assert ids == ~w(low none high high2)

      assert Enum.map(Requests.pending(), &{&1.bead_id, &1.priority}) ==
               [{"high", 1}, {"high2", 1}, {"low", 3}, {"none", nil}]

      {:ok, 0} = Priority.set({"sample", "low"}, 0, "user")
      assert Enum.map(Requests.pending(), & &1.bead_id) == ~w(low high high2 none)
    end
  end
end
