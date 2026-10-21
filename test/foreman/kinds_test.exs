defmodule Foreman.KindsTest do
  use ExUnit.Case, async: true

  test "own kind wins, otherwise nearest epic then repository default then unsorted" do
    beads = [
      node("root", "epic", "feature"),
      node("nested", "epic", "mapping", "root"),
      node("task", "task", nil, "nested"),
      node("own", "task", "access", "nested"),
      node("loose", "task", nil),
      node("cycle", "task", nil, "cycle"),
      node("inheriting", "epic", nil, "root"),
      node("descendant", "task", nil, "inheriting"),
      %{node("fallout", "bug", nil) | edges: [%{target: {"x", "task"}, type: "discovered-from"}]}
    ]

    resolved =
      Foreman.Initiatives.Kinds.resolve(beads, [%{"key" => "x", "default_kind" => "internal"}])

    assert Enum.map(resolved, &Map.get(&1, :effective_kind)) ==
             ~w(feature mapping mapping access internal internal feature feature mapping)

    assert [ticket] = Foreman.Initiatives.Kinds.resolve([node("loose", "task", nil)], [])
    assert ticket.effective_kind == "unsorted"
  end

  defp node(id, type, kind, parent \\ nil) do
    %{
      key: {"x", id},
      repo: "x",
      type: type,
      kind: kind,
      edges: if(parent, do: [%{target: {"x", parent}, type: "parent-child"}], else: [])
    }
  end

  test "repo default_kind accepts only ticket kinds" do
    for kind <- ~w(break_fix mapping access feature internal) do
      assert :ok =
               Foreman.Config.Schema.validate(%{
                 "repos" => [%{"key" => "x", "default_kind" => kind}]
               })
    end

    assert {:error, _} =
             Foreman.Config.Schema.validate(%{
               "repos" => [%{"key" => "x", "default_kind" => "wrong"}]
             })
  end
end
