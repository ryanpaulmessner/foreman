defmodule Foreman.RequestMachineTest do
  use ExUnit.Case, async: true
  alias Foreman.Request, as: Machine

  test "Continue is a pending usage-limit-only effect, never an approval job" do
    context = %{kind: "session_waiting", reason: "usage_limit"}
    assert Machine.step(:pending, :continue, context) == {:pending, [send: :continue]}

    for state <- Machine.__fsm__(:states), state != :pending do
      assert {:error, _} = Machine.step(state, :continue, context)
    end

    for context <- [
          %{kind: "session_waiting", reason: "input"},
          %{kind: "session_waiting", reason: "permission"},
          %{kind: "push", reason: "usage_limit"},
          %{kind: "decision", reason: "usage_limit"}
        ] do
      assert {:error, _} = Machine.step(:pending, :continue, context)
    end
  end

  test "an inline reply answers a single single-select question wait only" do
    question = %{"question" => "Which?", "options" => ["A", "B"], "multi" => false}
    context = %{kind: "session_waiting", reason: "input", questions: [question]}
    assert Machine.step(:pending, :reply, context) == {:answered, [send: :answer]}

    for state <- Machine.__fsm__(:states), state != :pending do
      assert {:error, _} = Machine.step(state, :reply, context)
    end

    for context <- [
          %{context | questions: nil},
          %{context | questions: [%{question | "multi" => true}]},
          %{context | questions: [Map.put(question, "preview", true)]},
          %{context | questions: [question, question]},
          %{context | questions: [%{question | "options" => []}]},
          %{context | reason: "permission"},
          %{context | kind: "decision"}
        ] do
      assert {:error, _} = Machine.step(:pending, :reply, context)
    end
  end

  test "a reply to a chat question types into the session prompt" do
    context = %{kind: "session_waiting", reason: "question", questions: nil}
    assert Machine.step(:pending, :reply, context) == {:answered, [send: :prompt]}

    for state <- Machine.__fsm__(:states), state != :pending do
      assert {:error, _} = Machine.step(state, :reply, context)
    end

    for context <- [%{context | reason: "input"}, %{context | kind: "decision"}] do
      assert {:error, _} = Machine.step(:pending, :reply, context)
    end
  end

  test "every request transition and its effects" do
    for {from, event, kind, to, effects} <- [
          {:new, :ask, "decision", :pending, [record: :request, notify: :pending]},
          {:pending, :approve, "push", :approved, [enqueue: :job]},
          {:pending, :answer, "decision", :answered, [record: :answer, notify: :asker]},
          {:pending, :decline, "decision", :declined, [record: :note, notify: :asker]},
          {:pending, :withdraw, "decision", :withdrawn, []},
          {:pending, :card_question, "decision", :pending, [send: :prompt]},
          {:pending, :card_reply, "decision", :pending, [record: :message]},
          {:pending, :facts_changed, "decision", :superseded, [notify: :asker]},
          {:approved, :start, "push", :executing, [audit: :intent]},
          {:executing, :succeeded, "push", :done, [audit: :result, notify: :asker]},
          {:executing, :failed, "push", :failed, [audit: :reason, notify: :asker]},
          {:executing, :orphaned, "push", :failed, [audit: :unknown, notify: :asker]}
        ] do
      assert Machine.step(from, event, %{kind: kind}) == {to, effects}
    end
  end

  test "wrong kind claims are invalid" do
    assert {:error, _} = Machine.step(:pending, :approve, %{kind: "decision"})
    assert {:error, _} = Machine.step(:pending, :answer, %{kind: "push"})
  end

  test "all other declared pairs reject claims and ignore observations" do
    valid =
      MapSet.new([
        {:new, :ask},
        {:pending, :approve},
        {:pending, :answer},
        {:pending, :decline},
        {:pending, :withdraw},
        {:pending, :card_question},
        {:pending, :card_reply},
        {:pending, :facts_changed},
        {:approved, :start},
        {:executing, :succeeded},
        {:executing, :failed},
        {:executing, :orphaned}
      ])

    for state <- Machine.__fsm__(:states),
        {event, source} <- Machine.__fsm__(:sources),
        not MapSet.member?(valid, {state, event}) do
      result = Machine.step(state, event, %{kind: "decision"})

      if source == :observed,
        do: assert(result == {state, []}),
        else: assert(match?({:error, _}, result))
    end
  end
end
