defmodule Foreman.SessionFocusTest do
  use ExUnit.Case, async: true

  test "coordinator and ticket focus both raise the terminal through the shared boundary" do
    for {project, ticket} <- [{"__foreman__", "coordinator"}, {"sample", "s-1"}] do
      session = %{project: project, ticket: ticket, session_id: "identity", window: "@2"}
      tmux_project = if project == "__foreman__", do: "coordinator", else: project

      runner = fn
        "osascript", _, _ ->
          send(self(), :activated)
          {"", 0}

        "tmux", args, _ ->
          cond do
            "list-windows" in args ->
              {"#{tmux_project}\t#{ticket}\t@2\trunning\t0\tidentity\n", 0}

            "list-clients" in args ->
              {"10\told\n20\tlatest\n", 0}

            "switch-client" in args ->
              send(self(), {:switched, Enum.take(args, -4)})
              {"", 0}
          end
      end

      assert :ok =
               Foreman.SessionTmux.focus(session,
                 runner: runner,
                 app: "WezTerm",
                 platform: {:unix, :darwin}
               )

      assert_receive {:switched, ["-c", "latest", "-t", "@2"]}
      assert_receive :activated
    end
  end

  test "a failed tmux switch reports unavailability without raising the terminal" do
    runner = fn
      ["list-clients" | _] -> {:ok, "10\tclient\n"}
      ["switch-client" | _] -> {:error, {:tmux, "client disappeared"}}
    end

    assert {:error, :tmux_unavailable} =
             Foreman.SessionFocus.show("%1", runner,
               app: "WezTerm",
               platform: {:unix, :darwin},
               runner: fn _, _, _ -> flunk("terminal raised after failed focus") end
             )
  end

  test "Go to session switches the latest client and raises WezTerm" do
    runner = fn
      "osascript", ["-e", script], _ ->
        send(self(), {:activation, script})
        {"", 0}

      "tmux", args, _ ->
        cond do
          "list-panes" in args ->
            {"%4\t@2\tcoordinator\tbuild\t1\n", 0}

          "list-clients" in args ->
            {"10\told\n20\tlatest\n", 0}

          "switch-client" in args ->
            send(self(), {:switch, Enum.take(args, -4)})
            {"", 0}

          true ->
            {"", 0}
        end
    end

    assert :ok =
             Foreman.RequestSource.focus(%{target: "%4", server: :default},
               runner: runner,
               app: "WezTerm",
               platform: {:unix, :darwin}
             )

    assert_receive {:switch, ["-c", "latest", "-t", "%4"]}
    assert_receive {:activation, ~s(tell application "WezTerm" to activate)}
  end
end
