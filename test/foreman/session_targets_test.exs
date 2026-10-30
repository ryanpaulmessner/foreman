defmodule Foreman.SessionTargetsTest do
  use ExUnit.Case, async: true

  test "an absent server is an empty listing, not a permission failure" do
    assert {:ok, []} =
             Foreman.SessionTargets.list(
               runner: fn _, _, _ ->
                 {"no server running on /private/tmp/tmux-501/default\n", 1}
               end
             )

    assert {:error, :tmux_unavailable} =
             Foreman.SessionTargets.list(runner: fn _, _, _ -> {"permission denied", 1} end)

    assert {:error, :tmux_unavailable} =
             Foreman.SessionTargets.list(runner: fn _, _, _ -> {"malformed", 0} end)
  end

  test "window tags use the active pane while duplicate window names stay ambiguous" do
    listing =
      "%1\t@1\tcoord\twork\t1\t\tname\n%2\t@1\tcoord\twork\t0\t\tname\n%3\t@2\tother\twork\t1\t\t\n"

    runner = fn _, _, _ -> {listing, 0} end
    assert {:ok, "%1"} = Foreman.SessionTargets.lookup("name", runner: runner)
    assert {:error, :window_gone} = Foreman.SessionTargets.lookup("work", runner: runner)
  end

  test "live lookup uses window names and pane-local build or session tags" do
    listing =
      "%1\t@1\tcoordinator\tfilter-design\t1\t\tfilter-redesign\n%2\t@1\tcoordinator\tfilter-design\t0\tbuild\tfilter-redesign\n%3\t@2\tcoordinator\tplain\t1\t\t\n"

    for {name, pane} <- [{"filter-redesign", "%1"}, {"build", "%2"}, {"plain", "%3"}] do
      assert {:ok, ^pane} =
               Foreman.SessionTargets.lookup(name, runner: fn "tmux", _, _ -> {listing, 0} end)
    end

    assert {:error, :window_gone} =
             Foreman.SessionTargets.lookup("unknown", runner: fn _, _, _ -> {listing, 0} end)
  end
end
