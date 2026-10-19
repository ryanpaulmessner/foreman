defmodule Foreman.SessionHooksTest do
  use ExUnit.Case, async: true

  test "hooks resolve foreman on the pane PATH, not the web release PATH" do
    settings =
      Foreman.SessionHooks.settings(%{project: "sample", ticket: "x-1", session_id: "test"})

    [entry] = settings["hooks"]["Stop"]
    [hook] = entry["hooks"]
    assert String.contains?(hook["command"], "timeout -k 1 3 'foreman' 'session-hook'")
  end

  test "question tools stay input waits across the permission hook" do
    input = %{"tool_name" => "AskUserQuestion", "tool_input" => %{"questions" => []}}

    assert {:waiting, %{"reason" => "input"} = facts} =
             Foreman.SessionHooks.facts("PreToolUse", input)

    assert Foreman.SessionHooks.facts("PermissionRequest", input) == {:waiting, facts}
    assert Foreman.SessionHooks.facts("PostToolUse", input) == {:resumed, facts["tool"]}

    answered =
      put_in(input, ["tool_input", "answers"], %{"question" => "Yes"})
      |> put_in(["tool_input", "annotations"], %{})

    assert Foreman.SessionHooks.facts("PostToolUse", answered) == {:resumed, facts["tool"]}
  end

  test "a question wait carries the question text and option labels, never answers" do
    input = %{
      "tool_name" => "AskUserQuestion",
      "tool_input" => %{
        "questions" => [
          %{
            "question" => "Which database?",
            "header" => "DB",
            "multiSelect" => false,
            "options" => [
              %{"label" => "Postgres", "description" => "Durable"},
              %{"label" => "SQLite", "description" => "Small"}
            ]
          }
        ],
        "answers" => %{"Which database?" => "Postgres"}
      }
    }

    for event <- ~w(PreToolUse PermissionRequest) do
      assert {:waiting, facts} = Foreman.SessionHooks.facts(event, input)

      assert facts["questions"] == [
               %{
                 "question" => "Which database?",
                 "options" => ["Postgres", "SQLite"],
                 "multi" => false,
                 "preview" => false
               }
             ]

      assert facts["tool_name"] == "AskUserQuestion"
      refute inspect(facts) =~ "Durable"
    end

    previewed =
      put_in(input, ["tool_input", "questions"], [
        %{
          "question" => "Layout?",
          "options" => [%{"label" => "Wide", "description" => "", "preview" => "┌──┐ secret"}]
        }
      ])

    assert {:waiting, %{"questions" => [%{"preview" => true, "options" => ["Wide"]}]} = facts} =
             Foreman.SessionHooks.facts("PreToolUse", previewed)

    refute inspect(facts) =~ "secret"
  end

  test "a permission wait names the tool and never carries its input" do
    input = %{
      "tool_name" => "Bash",
      "tool_input" => %{"command" => "rm -rf /tmp/secret-path"}
    }

    assert {:waiting, %{"reason" => "permission", "tool_name" => "Bash"} = facts} =
             Foreman.SessionHooks.facts("PermissionRequest", input)

    refute inspect(facts) =~ "secret-path"
    refute Map.has_key?(facts, "questions")
  end

  test "a Stop that ends on a question carries only the question paragraph" do
    message = "Ran the suite; 3 secret-ish details here.\n\nShall I commit it on feat/x?"

    assert Foreman.SessionHooks.facts("Stop", %{"last_assistant_message" => message}) ==
             {:waiting, %{"reason" => "question", "question" => "Shall I commit it on feat/x?"}}
  end

  @tag :tmp_dir
  test "a Stop reads the transcript tail when the hook has no last message", %{tmp_dir: dir} do
    path = Path.join(dir, "t.jsonl")

    entry = %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => "Want me to push?"}]}
    }

    File.write!(path, Jason.encode!(entry) <> "\n")

    assert {:waiting, %{"reason" => "question", "question" => "Want me to push?"}} =
             Foreman.SessionHooks.facts("Stop", %{"transcript_path" => path})
  end

  test "a Stop that does not ask is a plain idle wait" do
    for input <- [%{}, %{"last_assistant_message" => "Committed abc123."}] do
      assert Foreman.SessionHooks.facts("Stop", input) == {:waiting, %{"reason" => "input"}}
    end
  end

  test "API errors only report actual usage limits" do
    assert {:waiting,
            %{"reason" => "usage_limit", "provider" => "Anthropic", "reset_at" => "14:00"}} =
             Foreman.SessionHooks.facts("StopFailure", %{
               "error" => "rate_limit",
               "last_assistant_message" => "Usage limit reached; resets 14:00"
             })

    assert :activity =
             Foreman.SessionHooks.facts("StopFailure", %{"error" => "authentication_failed"})
  end

  test "CLI waiting facts preserve reason and coordinator target" do
    assert {:ok, %{request: request}} =
             Foreman.CLI.parse([
               "ask",
               "session_waiting",
               "x-1",
               "--session",
               "pi-build",
               "--reason",
               "usage_limit",
               "--window",
               "build",
               "--provider",
               "Codex",
               "--reset-at",
               "14:00"
             ])

    assert request["facts"] == %{
             "reason" => "usage_limit",
             "window" => "build",
             "provider" => "Codex",
             "reset_at" => "14:00"
           }
  end

  test "per-launch settings cover permission, input, turn completion, resumed tools and API errors without blocking Claude" do
    session = %{
      session_id: "7818e0a2-6213-40b3-87a2-39295b499fe0",
      project: "scratch",
      ticket: "x-1"
    }

    settings = Foreman.SessionHooks.settings(session, hook_executable: "/missing/foreman")
    assert Map.has_key?(settings, "hooks")

    for event <-
          ~w(PermissionRequest Stop UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure StopFailure) do
      assert [%{"hooks" => [%{"type" => "command", "command" => command, "timeout" => 4}]} | _] =
               settings["hooks"][event]

      assert command =~ session.session_id
      assert command =~ "'--project' 'scratch'"
      assert {"", 0} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)
    end
  end
end
