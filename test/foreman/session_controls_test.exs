defmodule Foreman.SessionControlsTest do
  @moduledoc "The live controls (spec Decision 17): which work now, and what each one does to tmux."
  use Foreman.DataCase, async: false
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, SessionCaptures, SessionControls, TestTmux}

  defp in_state(attrs, events) do
    Enum.reduce(events, agent_session(attrs), fn event, row ->
      {:ok, row, _} = AgentSessions.fire(row, event)
      row
    end)
  end

  defp off(controls, control) do
    case List.keyfind(controls, control, 0) do
      {_, {:off, reason}} -> reason
      _ -> nil
    end
  end

  defp on?(controls, control), do: List.keyfind(controls, control, 0) == {control, :on}

  describe "controls/2: on and off by state and kind" do
    test "a working build: Focus and Stop; no Park at all" do
      c = SessionControls.controls(in_state(%{}, [:output_changed]))
      assert Enum.map(c, &elem(&1, 0)) == [:answer, :continue, :focus, :message, :stop]
      assert on?(c, :focus) and on?(c, :stop)
      assert off(c, :answer) == "No card is open."
      assert off(c, :continue) == "Only after a usage limit."
      assert off(c, :message) == "The agent is working. A message now interrupts it."
    end

    test "an idle epic coordinator can take a message and park" do
      row =
        in_state(%{name: "epic", kind: "epic_coordinator", harness: "claude"}, [
          :output_changed,
          :quiet
        ])

      c = SessionControls.controls(row)
      assert on?(c, :message) and on?(c, :park) and on?(c, :stop)
    end

    test "the main coordinator never parks (R6)" do
      row = in_state(%{name: "coordinator", kind: "main_coordinator", harness: "claude"}, [])
      assert off(SessionControls.controls(row), :park) == "The main coordinator does not park."
    end

    test "a question: Answer and Send message" do
      c = SessionControls.controls(in_state(%{}, [:asked]), cards: 1)
      assert on?(c, :answer) and on?(c, :message)
      assert off(c, :continue) == "Only after a usage limit."
    end

    test "a usage limit: Continue, not Send message" do
      c = SessionControls.controls(in_state(%{}, [:usage_limit]), cards: 1)
      assert on?(c, :continue)
      assert off(c, :message) == "Use Continue at a usage limit."
    end

    test "a permission prompt: no message" do
      c = SessionControls.controls(in_state(%{}, [:permission_prompt]))
      assert off(c, :message) == "Answer the permission prompt in the terminal first."
      assert on?(c, :focus)
    end

    test "a dead session offers no live control (R3)" do
      row = %{} |> agent_session() |> AgentSessions.end_session()
      c = SessionControls.controls(row)

      for control <- [:continue, :focus, :message, :stop],
          do: assert(off(c, control) == "The pane is closed.")

      refute List.keymember?(c, :retry, 0)
    end

    test "tmux does not answer: the tmux controls are off and Try again now is on" do
      row =
        in_state(%{name: "epic", kind: "epic_coordinator", harness: "claude"}, [
          :output_changed,
          :quiet
        ])

      c = SessionControls.controls(row, tmux: :tmux_error)

      for control <- [:continue, :focus, :message, :park, :stop],
          do: assert(off(c, control) == "tmux does not answer.")

      assert on?(c, :retry)
    end
  end

  # A stand-in tmux: answers list-panes with `panes`, records every call.
  defp runner(panes, fail \\ []) do
    test = self()

    fn "tmux", args, _ ->
      send(test, {:tmux, args})
      command = Enum.find(args, &(&1 in ~w(list-panes capture-pane kill-pane send-keys)))

      cond do
        command in fail -> {"failed", 1}
        command == "list-panes" -> {panes, 0}
        command == "capture-pane" -> {"last output\n", 0}
        true -> {"", 0}
      end
    end
  end

  defp listing(rows),
    do:
      Enum.map_join(rows, "\n", fn {pane, name, tag, path} ->
        Enum.join([pane, name, "1", "2", tag, path], "\t")
      end)

  defp calls do
    receive do
      {:tmux, args} -> [args | calls()]
    after
      0 -> []
    end
  end

  describe "run/4 with a stand-in tmux" do
    setup do
      dir = Path.join(System.tmp_dir!(), "sc-controls-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "Stop saves the capture, then closes only the session's pane", %{dir: dir} do
      row = in_state(%{pane_id: "%5", workdir: dir}, [:output_changed])
      panes = listing([{"%4", "epic", "", dir}, {"%5", "epic", "", dir}])

      assert SessionControls.run(row, :stop, %{}, runner: runner(panes)) == :ok
      assert %{state: "ended", ended_at: %DateTime{}} = AgentSessions.get(row.id)
      assert %{reason: "stop", output: "last output\n"} = SessionCaptures.get(row.id)

      writes = Enum.filter(calls(), &("kill-pane" in &1 or "send-keys" in &1))
      assert writes == [["-N", "-L", "default", "kill-pane", "-t", "%5"]]
    end

    test "a failed capture closes nothing and leaves the row live", %{dir: dir} do
      row = in_state(%{pane_id: "%5", workdir: dir}, [:output_changed])
      panes = listing([{"%5", "b", "", dir}])

      assert SessionControls.run(row, :stop, %{}, runner: runner(panes, ["capture-pane"])) ==
               {:error, :tmux_unavailable}

      assert %{state: "working", ended_at: nil} = AgentSessions.get(row.id)
      refute Enum.any?(calls(), &("kill-pane" in &1))
    end

    test "a failed close rolls back the state and the saved capture", %{dir: dir} do
      row =
        in_state(
          %{
            name: "epic",
            kind: "epic_coordinator",
            harness: "claude",
            pane_id: "%5",
            workdir: dir
          },
          [:output_changed]
        )

      panes = listing([{"%5", "b", "", dir}])

      assert SessionControls.run(row, :park, %{}, runner: runner(panes, ["kill-pane"])) ==
               {:error, :tmux_unavailable}

      assert %{state: "working", ended_at: nil} = AgentSessions.get(row.id)
      assert SessionCaptures.get(row.id) == nil
    end

    test "Park saves a park capture and parks a coordinator", %{dir: dir} do
      row =
        in_state(
          %{
            name: "epic",
            kind: "epic_coordinator",
            harness: "claude",
            pane_id: "%5",
            workdir: dir
          },
          [:output_changed]
        )

      panes = listing([{"%5", "epic", "", dir}])
      assert SessionControls.run(row, :park, %{}, runner: runner(panes)) == :ok
      assert %{state: "parked"} = AgentSessions.get(row.id)
      assert %{reason: "park"} = SessionCaptures.get(row.id)
    end

    test "Park on a build is refused and touches no pane", %{dir: dir} do
      row = in_state(%{pane_id: "%5", workdir: dir}, [:output_changed])
      panes = listing([{"%5", "b", "", dir}])
      assert SessionControls.run(row, :park, %{}, runner: runner(panes)) == {:error, :invalid}
      refute Enum.any?(calls(), &("kill-pane" in &1 or "capture-pane" in &1))
    end

    test "a pane that runs in another directory is not this session", %{dir: dir} do
      row = in_state(%{pane_id: "%5", workdir: dir}, [:usage_limit])
      panes = listing([{"%5", "b", "", "/"}])

      assert SessionControls.run(row, :continue, %{}, runner: runner(panes)) ==
               {:error, :pane_changed}

      refute Enum.any?(calls(), &("send-keys" in &1))
    end

    test "a board row needs its window tag and loses it when its pane closes", %{dir: dir} do
      row =
        in_state(
          %{
            name: "epic",
            kind: "epic_coordinator",
            harness: "claude",
            tmux_server: "board",
            pane_id: "%5",
            workdir: dir
          },
          [:output_changed]
        )

      other = listing([{"%5", "epic", Ecto.UUID.generate(), dir}])

      assert SessionControls.run(row, :stop, %{}, runner: runner(other)) ==
               {:error, :pane_changed}

      tagged = listing([{"%5", "epic", row.id, dir}])
      assert SessionControls.run(row, :stop, %{}, runner: runner(tagged)) == :ok

      assert [
               "-N",
               "-L",
               "foreman",
               "set-option",
               "-w",
               "-u",
               "-t",
               "%5",
               "@foreman-session",
               ";",
               "kill-pane",
               "-t",
               "%5"
             ] in calls()
    end

    test "Continue outside a usage limit is refused before tmux is written", %{dir: dir} do
      row = in_state(%{pane_id: "%5", workdir: dir}, [:output_changed])
      panes = listing([{"%5", "b", "", dir}])
      assert SessionControls.run(row, :continue, %{}, runner: runner(panes)) == {:error, :invalid}
      refute Enum.any?(calls(), &("send-keys" in &1))
    end

    test "an empty message is refused", %{dir: dir} do
      row = in_state(%{pane_id: "%5", workdir: dir}, [:output_changed, :quiet])

      assert SessionControls.run(row, :message, %{"text" => "  "}, runner: runner("")) ==
               {:error, :answer_required}
    end

    test "a closed pane is window_gone", %{dir: dir} do
      row = in_state(%{pane_id: "%5", workdir: dir}, [:output_changed])
      assert SessionControls.run(row, :stop, %{}, runner: runner("")) == {:error, :window_gone}
      assert %{ended_at: nil} = AgentSessions.get(row.id)
    end

    test "the preview refuses every control" do
      row = in_state(%{pane_id: "%5"}, [:output_changed])
      System.put_env("PREVIEW", "1")
      on_exit(fn -> System.delete_env("PREVIEW") end)

      assert SessionControls.run(row, :stop, %{}, runner: runner("")) ==
               {:error, "refused in preview"}

      assert calls() == []
    end
  end

  describe "tmux on a scratch server" do
    # One window with a coordinator pane and a pane-mode build, as `pi-window` makes them.
    # Each pane reads one line and writes it to its own file, so the test sees what was typed.
    setup do
      socket = TestTmux.socket("sc-controls")
      dir = Path.join(System.tmp_dir!(), socket)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      reader = fn name ->
        "printf '───\\n❯ \\n───\\n'; read line; printf '%s' \"$line\" > #{dir}/#{name}.txt; tmux wait-for -S #{name}-#{socket}; sleep 30"
      end

      tmux = fn args -> System.cmd("tmux", ["-L", socket, "-f", "/dev/null" | args]) end

      {coord, 0} =
        tmux.(
          ~w(new-session -d -s proj -n epic -x 80 -y 20 -P -F #{"\#{pane_id}"} -c #{dir}) ++
            [reader.("coord")]
        )

      {build, 0} =
        tmux.(
          ~w(split-window -d -t proj:epic -P -F #{"\#{pane_id}"} -c #{dir}) ++ [reader.("build")]
        )

      Application.put_env(:foreman, :external_tmux_socket, socket)
      on_exit(fn -> Application.delete_env(:foreman, :external_tmux_socket) end)

      coordinator =
        in_state(
          %{
            name: "epic",
            kind: "epic_coordinator",
            harness: "claude",
            pane_id: String.trim(coord),
            workdir: dir
          },
          [:output_changed, :quiet]
        )

      build =
        in_state(
          %{
            name: "pane-build",
            parent_id: coordinator.id,
            harness: "claude",
            pane_id: String.trim(build),
            workdir: dir
          },
          [:output_changed]
        )

      %{socket: socket, dir: dir, tmux: tmux, coordinator: coordinator, build: build}
    end

    defp opts, do: [runner: &System.cmd/3, key_delay: 50, platform: :none]

    defp panes(tmux) do
      {out, 0} = tmux.(~w(list-panes -a -F #{"\#{pane_id}"}))
      String.split(out, "\n", trim: true)
    end

    test "Continue types only continue and Enter into the build pane (acceptance 8)", ctx do
      {:ok, build, _} = AgentSessions.fire(ctx.build, :usage_limit)
      assert SessionControls.run(build, :continue, %{}, opts()) == :ok
      {_, 0} = ctx.tmux.(["wait-for", "build-#{ctx.socket}"])
      assert File.read!(Path.join(ctx.dir, "build.txt")) == "continue"
      refute File.exists?(Path.join(ctx.dir, "coord.txt"))
    end

    test "Send message types the line into the session's own pane", ctx do
      assert SessionControls.run(
               ctx.coordinator,
               :message,
               %{"text" => "Check the build"},
               opts()
             ) == :ok

      {_, 0} = ctx.tmux.(["wait-for", "coord-#{ctx.socket}"])
      assert File.read!(Path.join(ctx.dir, "coord.txt")) == "Check the build"
      refute File.exists?(Path.join(ctx.dir, "build.txt"))
    end

    test "Park closes the coordinator's pane; the build pane and the window stay (acceptance 7)",
         ctx do
      assert SessionControls.run(ctx.coordinator, :park, %{}, opts()) == :ok
      assert panes(ctx.tmux) == [ctx.build.pane_id]
      assert %{state: "parked"} = AgentSessions.get(ctx.coordinator.id)
      assert %{reason: "park", output: output} = SessionCaptures.get(ctx.coordinator.id)
      assert output =~ "❯"
    end

    test "Stop on the build closes only its pane and keeps its worktree (acceptance 6)", ctx do
      assert SessionControls.run(ctx.build, :stop, %{}, opts()) == :ok
      assert panes(ctx.tmux) == [ctx.coordinator.pane_id]
      assert File.dir?(ctx.dir)
      assert %{state: "ended"} = AgentSessions.get(ctx.build.id)
      assert %{reason: "stop"} = SessionCaptures.get(ctx.build.id)
    end

    test "Focus switches the attached client to the session's pane", ctx do
      client = Port.open({:spawn, "tmux -L #{ctx.socket} -C attach -t proj"}, [:binary])
      on_exit(fn -> if Port.info(client), do: Port.close(client) end)
      wait_for_client(ctx.tmux, 50)

      assert SessionControls.run(ctx.build, :focus, %{}, opts()) == :ok
      {active, 0} = ctx.tmux.(~w(display-message -p -t proj #{"\#{pane_id}"}))
      assert String.trim(active) == ctx.build.pane_id
    end

    test "Focus with no attached terminal says so", ctx do
      assert SessionControls.run(ctx.build, :focus, %{}, opts()) == {:ok, :no_client}
    end
  end

  defp wait_for_client(tmux, tries) do
    {out, _} = tmux.(~w(list-clients -F #{"\#{client_name}"}))

    cond do
      String.trim(out) != "" -> :ok
      tries == 0 -> flunk("no tmux client attached")
      true -> receive(after: (20 -> wait_for_client(tmux, tries - 1)))
    end
  end
end
