defmodule Foreman.CardReplyCLITest do
  use Foreman.DataCase, async: false

  @tag :tmp_dir
  test "body files preserve Markdown and ambiguous or invalid input is refused", %{tmp_dir: dir} do
    path = Path.join(dir, "reply.md")
    File.write!(path, "# Why\n\nBecause.\n")
    id = Ecto.UUID.generate()

    assert {:ok, %{request: %{"body" => "# Why\n\nBecause.\n"}}} =
             Foreman.CLI.parse(["card-reply", id, "--body-file", path])

    for args <- [
          [],
          ["--text", " "],
          ["--text", "yes", "--body-file", path],
          ["--body-file", path <> "missing"],
          ["--text", String.duplicate("a", 20_001)]
        ] do
      assert {:error, _} = Foreman.CLI.parse(["card-reply", id | args])
    end
  end

  test "card-reply carries text and identity to an idempotent command" do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Ticket", issue_type: "task", status: "open"})
    )

    {:ok, r} =
      Foreman.Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      })

    assert {:ok, %{request: command, json: true}} =
             Foreman.CLI.parse(["card-reply", r.id, "--text", "**Because**", "--json"],
               actor: "pi",
               session: "build"
             )

    assert command["action"] == "card_reply"
    assert command["id"] == r.id
    assert command["body"] == "**Because**"
    command = Map.put(command, "request_id", Ecto.UUID.generate())
    assert {200, %{id: id}} = Foreman.AgentCommands.execute(command)
    assert {200, %{"id" => ^id}} = Foreman.AgentCommands.execute(command)
    assert [%{author: "pi · build", body: "**Because**"}] = Foreman.CardMessages.list(r.id)

    assert {404, %{error: :not_found}} =
             Foreman.AgentCommands.execute(%{
               command
               | "id" => Ecto.UUID.generate(),
                 "request_id" => Ecto.UUID.generate()
             })

    Foreman.Requests.resolve(r.id, :decline, %{})

    assert {422, %{error: :request_finished}} =
             Foreman.AgentCommands.execute(%{command | "request_id" => Ecto.UUID.generate()})
  end
end
