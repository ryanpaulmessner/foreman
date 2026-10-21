defmodule Foreman.AnswerCLITest do
  use Foreman.DataCase, async: false
  alias Foreman.{CLI, AgentCommands, Answers}

  test "running the CLI prints the stored id and page URL through the authenticated API" do
    file = Path.join(System.tmp_dir!(), "answer-http-#{System.unique_integer([:positive])}.md")
    token = file <> ".token"
    File.write!(file, "Saved through HTTP")
    File.write!(token, "test-only-token-long")
    old = Application.get_env(:foreman, :token_file)
    Application.put_env(:foreman, :token_file, token)

    on_exit(fn ->
      File.rm(file)
      File.rm(token)

      if old,
        do: Application.put_env(:foreman, :token_file, old),
        else: Application.delete_env(:foreman, :token_file)
    end)

    Req.Test.stub(__MODULE__, fn conn -> ForemanWeb.Endpoint.call(conn, []) end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert CLI.run(["answer", "--question", "Saved?", "--body-file", file],
                 req_options: [plug: {Req.Test, __MODULE__}]
               ) == 0
      end)

    assert [answer] = Answers.list()
    assert output =~ "#{answer.id} "
    assert output =~ "/answers?id=#{answer.id}"
    assert hd(answer.versions).body == "Saved through HTTP"
    warning = ExUnit.CaptureIO.capture_io(fn -> CLI.run(["answer"]) end)
    assert warning =~ "--body-file"
  end

  test "existing caller-relative links retain their worktree path" do
    root = Path.join(System.tmp_dir!(), "answer-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "note.md"), "Note")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, %{request: request}} =
             CLI.parse(
               [
                 "answer",
                 "--question",
                 "Where?",
                 "--body-file",
                 Path.join(root, "note.md"),
                 "--link",
                 "note.md",
                 "--link",
                 "https://example.com"
               ],
               cwd: root
             )

    assert request["payload"]["links"] == [Path.join(root, "note.md"), "https://example.com"]
  end

  test "bad input is refused with a useful message" do
    for args <- [
          ["answer"],
          ["answer", "--update", "bad-id", "--body-file", "missing.md"],
          ["answer", "--question", "Why?", "--body-file", "missing.md"],
          ["answer", "--unknown", "x"]
        ] do
      assert {:error, message} = CLI.parse(args)
      assert message =~ "--body-file"
    end

    assert {422, %{error: error}} =
             AgentCommands.execute(%{
               "action" => "answer",
               "payload" => %{"question" => "", "body" => "", "actor" => "pi"}
             })

    assert error =~ "invalid_answer"
    assert Answers.list() == []

    for links <- [nil, [nil], [String.duplicate("a", 4097)]] do
      assert {422, _} =
               AgentCommands.execute(%{
                 "action" => "answer",
                 "payload" => %{
                   "question" => "Why?",
                   "body" => "Text",
                   "actor" => "pi",
                   "links" => links
                 }
               })
    end

    assert {404, _} =
             AgentCommands.execute(%{
               "action" => "answer",
               "update" => Ecto.UUID.generate(),
               "payload" => %{"body" => "Text", "actor" => "pi"}
             })
  end

  test "CLI envelopes store answers and replay an update only once" do
    file = Path.join(System.tmp_dir!(), "answer-#{System.unique_integer([:positive])}.md")
    File.write!(file, "**Saved**\n")
    on_exit(fn -> File.rm(file) end)

    assert {:ok, %{request: request}} =
             CLI.parse(
               [
                 "answer",
                 "--question",
                 "What?",
                 "--body-file",
                 file,
                 "--repo",
                 "sample",
                 "--ticket",
                 "fm-1",
                 "--link",
                 "https://example.com",
                 "--link",
                 "docs/spec.md"
               ],
               actor: "pi",
               session: "build",
               cwd: System.tmp_dir!()
             )

    request = Map.put(request, "request_id", Ecto.UUID.generate())
    assert {200, %{id: id, url: url}} = AgentCommands.execute(request)
    assert url == "/answers?id=#{id}"
    assert [version] = Answers.get(id).versions
    assert version.body == "**Saved**\n"
    assert version.links == ["https://example.com", "docs/spec.md"]
    assert {200, %{"id" => ^id}} = AgentCommands.execute(request)

    assert {:ok, %{request: update}} =
             CLI.parse(["answer", "--update", id, "--body-file", file], actor: "pi")

    update = Map.put(update, "request_id", Ecto.UUID.generate())
    assert {200, %{id: ^id}} = AgentCommands.execute(update)
    assert {200, %{"id" => ^id}} = AgentCommands.execute(update)
    assert length(Answers.get(id).versions) == 2
  end
end
