defmodule Foreman.CLITest do
  use ExUnit.Case, async: true
  alias Foreman.CLI

  test "ticket verbs encode their claims with actor/session defaults" do
    for {verb, event} <- [
          {"dispatch", "dispatch"},
          {"progress", "progress"},
          {"report", "report"},
          {"review", "review"},
          {"changes", "request_changes"},
          {"commit", "commit"},
          {"abandon", "abandon"},
          {"revive", "revive"}
        ] do
      assert {:ok,
              %{
                request: %{
                  "id" => "s-1",
                  "event" => ^event,
                  "actor" => "pi",
                  "session" => "build"
                },
                json: true
              }} = CLI.parse([verb, "s-1", "--json"], actor: "pi", session: "build", cwd: "/work")
    end

    assert {:ok, %{request: %{"payload" => %{"body" => "working"}}}} =
             CLI.parse(["progress", "s-1", "working"])

    assert {:ok, %{request: %{"payload" => %{"window" => "build", "branch" => "feature"}}}} =
             CLI.parse(["dispatch", "s-1", "--window", "build", "--branch", "feature"])
  end

  test "ask decision --doc repeats; cwd-relative files become absolute, others stay repo-relative" do
    cwd =
      Foreman.ScratchDocs.write(Foreman.ScratchDocs.dir("cli-docs"), %{"drafts/r.md" => "# R"})

    on_exit(fn -> File.rm_rf!(cwd) end)

    assert {:ok, %{request: %{"facts" => facts}}} =
             CLI.parse(
               ~w(ask decision s-1 --question Ship? --doc drafts/r.md --doc docs/spec.md --doc /abs/x.md),
               cwd: cwd
             )

    assert facts["docs"] == [Path.join(cwd, "drafts/r.md"), "docs/spec.md", "/abs/x.md"]

    assert {:ok, %{request: %{"facts" => facts}}} =
             CLI.parse(~w(ask decision s-1 --question Ship?), cwd: cwd)

    refute Map.has_key?(facts, "docs")
  end

  test "approve carries the optional design path" do
    assert {:ok,
            %{
              request: %{
                "payload" => %{"spec_link" => "docs/spec.md", "design_link" => "docs/design.md"}
              }
            }} =
             CLI.parse(
               ~w(epic approve draft:pack --project sample --spec docs/spec.md --design docs/design.md)
             )
  end

  test "draft verbs use slugs and cwd or explicit project" do
    for {verb, event} <- [
          {"create", "create"},
          {"spec", "start_spec"},
          {"approve", "approve_spec"},
          {"ticket", "ticket"},
          {"abandon", "abandon"},
          {"revive", "revive"}
        ] do
      assert {:ok,
              %{
                request: %{
                  "id" => "draft:new-idea",
                  "event" => ^event,
                  "cwd" => "/work",
                  "project" => "sample"
                }
              }} =
               CLI.parse(["epic", verb, "draft:new-idea", "--project", "sample"], cwd: "/work")
    end

    assert {:ok, %{request: %{"id" => "s-e"}}} = CLI.parse(["epic", "abandon", "s-e"])
  end

  test "link verbs and read commands have stable envelopes; malformed options are warnings" do
    for verb <- ["attach", "detach"] do
      assert {:ok, %{request: %{"action" => ^verb, "id" => "s-1", "epic" => "o-e"}}} =
               CLI.parse([verb, "s-1", "--epic", "o-e"])
    end

    assert {:ok, %{request: %{"action" => "show"}}} = CLI.parse(["show", "s-1"])

    assert {:ok, %{request: %{"action" => "ls", "stage" => "building"}}} =
             CLI.parse(["ls", "--stage", "building"])

    assert {:error, :usage} = CLI.parse(["review", "s-1", "--typo"])
  end
end
