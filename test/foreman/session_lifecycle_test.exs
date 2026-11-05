defmodule Foreman.SessionLifecycleTest do
  @moduledoc "One test per row of spec Decision 7, then the rules (Decision 8) the machine owns."
  use ExUnit.Case, async: true
  alias Foreman.SessionLifecycle, as: M

  @live [
    :starting,
    :working,
    :idle,
    :waiting_question,
    :waiting_permission,
    :waiting_usage_limit
  ]
  @dead [:parked, :ended]
  @active [:starting, :working, :idle]
  @kinds ~w(main_coordinator epic_coordinator build)
  @claimed [
    :launch,
    :register,
    :continue,
    :focus,
    :message,
    :resume_on_model,
    :park,
    :stop,
    :resume,
    :start_fresh,
    :relaunch_build
  ]
  @observed [
    :output_changed,
    :quiet,
    :asked,
    :last_card_closed,
    :permission_prompt,
    :usage_limit,
    :prompt_cleared,
    :idle_timeout,
    :pane_gone,
    :exited
  ]

  defp data(kind, extra \\ %{}), do: Map.merge(%{kind: kind, harness: "claude"}, extra)

  describe "Decision 7 table" do
    test "(none) launch, register -> starting, writing the row" do
      for kind <- @kinds do
        assert M.step(:none, :launch, data(kind)) == {:starting, [write: :row, open: :window]}
        assert M.step(:none, :register, data(kind)) == {:starting, [write: :row]}
      end
    end

    test "starting, idle output_changed -> working" do
      for state <- [:starting, :idle],
          do: assert(M.step(state, :output_changed, %{}) == {:working, []})
    end

    test "working quiet -> idle" do
      assert M.step(:working, :quiet, %{}) == {:idle, []}
    end

    test "starting, working, idle asked -> waiting.question" do
      for state <- @active, do: assert(M.step(state, :asked, %{}) == {:waiting_question, []})
    end

    test "starting, working, idle permission_prompt -> waiting.permission with the request" do
      for state <- @active,
          do:
            assert(
              M.step(state, :permission_prompt, %{}) ==
                {:waiting_permission, [request: :permission]}
            )
    end

    test "starting, working, idle usage_limit -> waiting.usage_limit with the request" do
      for state <- @active,
          do:
            assert(
              M.step(state, :usage_limit, %{}) == {:waiting_usage_limit, [request: :usage_limit]}
            )
    end

    test "waiting.question last_card_closed -> idle" do
      assert M.step(:waiting_question, :last_card_closed, %{}) == {:idle, []}
    end

    test "waiting.permission prompt_cleared -> working, clearing the request" do
      assert M.step(:waiting_permission, :prompt_cleared, %{}) == {:working, [clear: :request]}
    end

    test "any live focus stays and shows this pane (Decision 17)" do
      for state <- @live,
          kind <- @kinds,
          do: assert(M.step(state, :focus, data(kind)) == {state, [show: :pane]})
    end

    test "idle, waiting.question message stays and types into this pane (Decision 17)" do
      for state <- [:idle, :waiting_question],
          kind <- @kinds,
          do: assert(M.step(state, :message, data(kind)) == {state, [send: :message]})

      for state <- [:starting, :working, :waiting_permission, :waiting_usage_limit],
          do:
            assert(
              M.step(state, :message, data("build")) == {:error, {:invalid, state, :message}}
            )
    end

    test "waiting.usage_limit continue stays and sends continue to this pane" do
      for kind <- @kinds,
          do:
            assert(
              M.step(:waiting_usage_limit, :continue, data(kind)) ==
                {:waiting_usage_limit, [send: :continue]}
            )
    end

    test "waiting.usage_limit output_changed -> working, clearing the request" do
      assert M.step(:waiting_usage_limit, :output_changed, %{}) == {:working, [clear: :request]}
    end

    test "waiting.usage_limit resume_on_model -> starting, Pi builds only" do
      assert M.step(:waiting_usage_limit, :resume_on_model, data("build", %{harness: "pi"})) ==
               {:starting, [save: :capture, stop: :process, resume: :model]}

      for data <- [
            data("build"),
            data("epic_coordinator", %{harness: "pi"}),
            data("main_coordinator")
          ] do
        assert M.step(:waiting_usage_limit, :resume_on_model, data) ==
                 {:error, {:invalid, :waiting_usage_limit, :resume_on_model}}
      end
    end

    test "any live, coordinator not main: park (user), idle_timeout (observed) -> parked" do
      for state <- @live, event <- [:park, :idle_timeout] do
        assert M.step(state, event, data("epic_coordinator")) ==
                 {:parked, [save: :capture, close: :pane]}
      end
    end

    test "any live stop -> ended, saving the capture and closing this pane" do
      for state <- @live, kind <- @kinds do
        assert M.step(state, :stop, data(kind)) == {:ended, [save: :capture, close: :pane]}
      end
    end

    test "any live pane_gone, exited -> ended, saving the capture" do
      for state <- @live, event <- [:pane_gone, :exited], kind <- @kinds do
        assert M.step(state, event, data(kind)) == {:ended, [save: :capture]}
      end
    end

    test "parked, ended resume [resumable] -> starting on the same conversation" do
      for state <- @dead, kind <- @kinds do
        assert M.step(state, :resume, data(kind, %{resumable: true})) ==
                 {:starting, [resume: :conversation]}
      end
    end

    test "parked, ended, coordinator start_fresh [not resumable]: old row stays" do
      for state <- @dead, kind <- ~w(main_coordinator epic_coordinator) do
        assert M.step(state, :start_fresh, data(kind, %{resumable: false})) ==
                 {state, [create: :row, move: :builds]}
      end
    end

    test "ended build relaunch_build [not resumable]: row stays ended" do
      assert M.step(:ended, :relaunch_build, data("build", %{resumable: false})) ==
               {:ended, [resume: :parent, note: :relaunch]}
    end

    test "any other pair: claimed events refused, observed events ignored" do
      table = table()

      for state <- M.__fsm__(:states),
          event <- @claimed ++ @observed,
          kind <- @kinds,
          resumable <- [true, false],
          harness <- ~w(claude pi),
          not MapSet.member?(table, {state, event, kind, resumable, harness}) do
        result = M.step(state, event, %{kind: kind, resumable: resumable, harness: harness})

        if event in @claimed,
          do: assert(result == {:error, {:invalid, state, event}}, inspect({state, event, kind})),
          else: assert(result == {state, []}, inspect({state, event, kind}))
      end
    end
  end

  # Every (state, event, data) the table above allows.
  defp table do
    for kind <- @kinds,
        resumable <- [true, false],
        harness <- ~w(claude pi),
        into: MapSet.new() do
      d = %{kind: kind, resumable: resumable, harness: harness}

      [
        {:none, :launch},
        {:none, :register},
        {:starting, :output_changed},
        {:idle, :output_changed},
        {:working, :quiet},
        {:waiting_question, :last_card_closed},
        {:waiting_permission, :prompt_cleared},
        {:waiting_usage_limit, :continue},
        {:waiting_usage_limit, :output_changed},
        {:idle, :message},
        {:waiting_question, :message}
      ]
      |> Kernel.++(for s <- @active, e <- [:asked, :permission_prompt, :usage_limit], do: {s, e})
      |> Kernel.++(for s <- @live, e <- [:stop, :focus, :pane_gone, :exited], do: {s, e})
      |> Kernel.++(
        if kind == "epic_coordinator",
          do: for(s <- @live, e <- [:park, :idle_timeout], do: {s, e}),
          else: []
      )
      |> Kernel.++(
        if kind == "build" and harness == "pi",
          do: [{:waiting_usage_limit, :resume_on_model}],
          else: []
      )
      |> Kernel.++(if resumable, do: for(s <- @dead, do: {s, :resume}), else: [])
      |> Kernel.++(
        if not resumable and kind != "build", do: for(s <- @dead, do: {s, :start_fresh}), else: []
      )
      |> Kernel.++(
        if not resumable and kind == "build", do: [{:ended, :relaunch_build}], else: []
      )
      |> Enum.map(fn {s, e} -> {s, e, d.kind, d.resumable, d.harness} end)
    end
    |> Enum.reduce(MapSet.new(), &MapSet.union(MapSet.new(&1), &2))
  end

  describe "rules the machine owns (Decision 8)" do
    test "R3: a dead session refuses Focus, Send message, Continue, Park and Stop" do
      for state <- @dead, event <- [:focus, :message, :continue, :park, :stop], kind <- @kinds do
        assert M.step(state, event, data(kind)) == {:error, {:invalid, state, event}}
      end
    end

    test "R4: Resume only when resumable; otherwise Relaunch build or Start fresh" do
      for state <- @dead, kind <- @kinds do
        assert M.step(state, :resume, data(kind, %{resumable: false})) ==
                 {:error, {:invalid, state, :resume}}

        assert {:error, _} = M.step(state, :start_fresh, data(kind, %{resumable: true}))
        assert {:error, _} = M.step(state, :relaunch_build, data(kind, %{resumable: true}))
      end

      assert {:error, _} = M.step(:ended, :start_fresh, data("build", %{resumable: false}))

      for kind <- ~w(main_coordinator epic_coordinator),
          do:
            assert({:error, _} = M.step(:ended, :relaunch_build, data(kind, %{resumable: false})))
    end

    test "R5: no effect of the machine deletes a worktree or a branch" do
      effects =
        for row <- M.__fsm__(:rows),
            row.kind == :transition,
            {name, arg} <- row.effects,
            do: {name, arg}

      refute Enum.any?(effects, fn {name, arg} ->
               arg in [:worktree, :branch] or name == :delete
             end)

      for state <- @live,
          do:
            assert(
              M.step(state, :stop, data("build")) == {:ended, [save: :capture, close: :pane]}
            )
    end

    test "R6: the main coordinator is never parked" do
      for state <- @live do
        assert M.step(state, :park, data("main_coordinator")) ==
                 {:error, {:invalid, state, :park}}

        assert M.step(state, :idle_timeout, data("main_coordinator")) == {state, []}
      end
    end

    test "R6 and Decision 17: builds never park" do
      for state <- @live do
        assert M.step(state, :park, data("build")) == {:error, {:invalid, state, :park}}
        assert M.step(state, :idle_timeout, data("build")) == {state, []}
      end
    end

    test "R8: Relaunch build resumes the parent first, then sends it the note" do
      assert {:ended, [resume: :parent, note: :relaunch]} =
               M.step(:ended, :relaunch_build, data("build", %{resumable: false}))
    end

    test "R9: ending a session that waits on a card never clears its cards" do
      for event <- [:stop, :pane_gone, :exited],
          {:ended, effects} = M.step(:waiting_question, event, data("build")),
          do: refute(Keyword.has_key?(effects, :clear))
    end

    test "R10: every dead build has Resume or Relaunch build" do
      # A build never parks (R6), so its only dead state is ended.
      for resumable <- [true, false] do
        d = data("build", %{resumable: resumable})

        assert match?({:starting, _}, M.step(:ended, :resume, d)) or
                 match?({:ended, _}, M.step(:ended, :relaunch_build, d))
      end
    end

    test "R11: Park and Stop close only the session's own pane" do
      assert {:parked, effects} = M.step(:working, :park, data("epic_coordinator"))
      assert effects[:close] == :pane
      assert {:ended, effects} = M.step(:working, :stop, data("epic_coordinator"))
      assert effects[:close] == :pane

      refute Enum.any?(M.__fsm__(:rows), &({:close, :window} in &1.effects))
    end
  end

  test "stored values round-trip and use the spec's dotted waiting names" do
    assert M.dump(:waiting_question) == "waiting.question"
    assert M.load("waiting.usage_limit") == :waiting_usage_limit
    assert M.load(nil) == :none
    for state <- M.__fsm__(:states) -- [:none], do: assert(M.load(M.dump(state)) == state)
  end
end
