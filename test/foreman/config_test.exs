defmodule Foreman.ConfigTest do
  use ExUnit.Case, async: true

  test "ticket source defaults to beads and permits a per-repo files override" do
    base = "[[repos]]\nkey = \"sample\"\npath = \"/tmp/sample\"\n"
    assert {:ok, config} = parse(base)
    assert hd(config["repos"])["tickets"] == "beads"
    assert {:ok, config} = parse(base <> "tickets = \"files\"\n")
    assert hd(config["repos"])["tickets"] == "files"
    assert {:error, error} = parse(base <> "tickets = \"other\"\n")
    assert error =~ "tickets"
  end

  test "shipped views are ordered with Open first" do
    assert {:ok, config} = parse("")
    assert Enum.map(config["views"] || [], & &1["key"]) == ~w(open in-flight stale all)
    assert hd(config["views"])["statuses"] == ~w(open in_progress blocked deferred)
  end

  test "curated views replace defaults in order and rejected reloads retain the last good set" do
    assert {:ok, config} =
             parse("""
             [[views]]
             key = "review"
             title = "Review"
             stages = ["reported", "in_review"]
             statuses = ["open", "in_progress"]
             stale = false
             """)

    assert Enum.map(config["views"], & &1["key"]) == ["review"]

    for text <- [
          "views = []",
          "[[views]]\nkey = \"oops\"",
          "[[views]]\ntitle = \"Oops\"",
          "[[views]]\nkey = \"oops\"\ntitle = \"Oops\"\nstages = [\"speccing\"]",
          "[[views]]\nkey = \"oops\"\ntitle = \"Oops\"\nstatuses = [\"invented\"]",
          "[[views]]\nkey = \"oops\"\ntitle = \"Oops\"\nstale = \"yes\"",
          "[[views]]\nkey = \"same\"\ntitle = \"One\"\n[[views]]\nkey = \"same\"\ntitle = \"Two\""
        ] do
      assert {:error, error} = rejected = parse(text)
      assert error =~ "views"
      {loading, _} = config |> Foreman.Config.Reload.new() |> Foreman.Config.Reload.request()
      {retained, _} = Foreman.Config.Reload.complete(loading, loading.generation, rejected)
      assert retained.config == config
      assert retained.error == error
    end
  end

  test "unknown stages are rejected with the source and field" do
    assert {:error, error} = parse("[[columns]]\ntitle = \"Oops\"\nstages = [\"speccing\"]")
    assert error =~ "foreman.toml"
    assert error =~ "columns[0].stages"
    assert error =~ "speccing"
  end

  test "bad TOML is an error, not a crash" do
    assert {:error, "foreman.toml: invalid TOML"} = parse("[board\n")
  end

  test "malformed shapes, unknown options and duplicate identities are rejected" do
    for text <- [
          "repos = [1]",
          "repos = false",
          "columns = {}",
          "unknown = true",
          "[board]\nswimlanes = false",
          "[board]\nstale_session_after = \"soon\"",
          "[board]\nstale_session_after = \"0h\"",
          "[board]\nterminal_app = \"Ghostty\\\" to quit\"",
          "[[columns]]\ntitle = \"X\"\nstages = []",
          "[[repos]]\nkey = \"sample\"\npath = \"relative/path\"",
          "[[repos]]\nkey = \"sample\"\npath = \"~/dev/sample\"\nenabled = \"yes\"",
          "[[repos]]\nkey = \"sample\"\npath = \"~/dev/sample\"\nforge = \"unknown\"",
          "[[repos]]\nkey = \"sample\"\npath = \"~/dev/sample\"\n[[repos]]\nkey = \"sample\"\npath = \"~/dev/other\"",
          "[[repos]]\nkey = \"sample\"\npath = \"~/dev/sample\"\n[[repos]]\nkey = \"other\"\npath = \"~/dev/sample/.\"",
          "[backfill]\ndefault = \"speccing\"",
          "[epics.\"fe-1\"]\npin = 1"
        ] do
      assert {:error, _} = parse(text), text
    end
  end

  test "empty repos clears inherited repos and omitted files leave shipped defaults" do
    assert {:ok, config} = parse("repos = []")
    assert config["repos"] == []
    assert length(config["columns"]) == 5
  end

  describe "merge policy" do
    @work_repo """
    [[repos]]
    key = "work"
    path = "~/dev/work"
    prefix = "work"
    tickets = "files"
    """

    test "the user's work repo shape loads as human merge on staging" do
      assert {:ok, config} =
               parse(
                 @work_repo <>
                   """
                   github = "AGarcia-IHS/ReportSystem"
                   forge = "github"
                   merge_policy = "human"
                   merge_base = "staging"
                   """
               )

      [repo] = config["repos"]
      assert %{"merge_policy" => "human", "merge_base" => "staging"} = repo
      assert Foreman.MergePolicy.human?(repo, config)
      assert Foreman.MergePolicy.base(repo, "main") == "staging"
      assert Foreman.MergePolicy.protected_branches(repo, "main") == ["staging", "main"]
    end

    test "the default stays board merge, and a top-level value sets it for every repo" do
      github = @work_repo <> "github = \"o/r\"\n"
      assert {:ok, config} = parse(github)
      refute Map.has_key?(config, "merge_policy")
      refute Map.has_key?(hd(config["repos"]), "merge_policy")
      assert Foreman.MergePolicy.policy(hd(config["repos"]), config) == "board"

      assert {:ok, config} = parse("merge_policy = \"human\"\n" <> github)
      assert Foreman.MergePolicy.policy(hd(config["repos"]), config) == "human"
      assert Foreman.MergePolicy.base(hd(config["repos"]), "main") == "main"

      assert {:ok, config} =
               parse("merge_policy = \"human\"\n" <> github <> "merge_policy = \"board\"\n")

      assert Foreman.MergePolicy.policy(hd(config["repos"]), config) == "board"
    end

    test "policy values and base names are validated at both levels" do
      for text <- [
            "merge_policy = \"auto\"",
            "merge_policy = true",
            @work_repo <> "merge_policy = \"squash\"",
            @work_repo <> "merge_base = \"+staging\"",
            @work_repo <> "merge_base = \"\""
          ] do
        assert {:error, error} = parse(text), text
        assert error =~ "merge_"
      end
    end

    test "human merge without a GitHub forge is a load error that keeps the last good config" do
      assert {:ok, good} = parse(@work_repo)

      for text <- [
            @work_repo <> "merge_policy = \"human\"",
            @work_repo <> "forge = \"none\"\ngithub = \"o/r\"\nmerge_policy = \"human\"",
            "merge_policy = \"human\"\n" <> @work_repo
          ] do
        assert {:error, error} = rejected = parse(text)
        assert error =~ "repos[0] (work): merge_policy \"human\" requires forge = \"github\""
        {loading, _} = good |> Foreman.Config.Reload.new() |> Foreman.Config.Reload.request()
        {retained, _} = Foreman.Config.Reload.complete(loading, loading.generation, rejected)
        assert retained.config == good
        assert retained.error == error
      end
    end

    test "a local layer may set the policy on a repo whose forge is in the global file" do
      global = @work_repo <> "github = \"AGarcia-IHS/ReportSystem\"\n"
      local = "[[repos]]\nkey = \"work\"\nmerge_policy = \"human\"\nmerge_base = \"staging\"\n"

      assert {:ok, config} =
               Foreman.Config.parse_layers(
                 [
                   {"defaults", File.read!("priv/foreman.defaults.toml")},
                   {"foreman.toml", global},
                   {"foreman.local.toml", local}
                 ],
                 home: "/tmp/config-home"
               )

      assert Foreman.MergePolicy.human?(hd(config["repos"]), config)
    end
  end

  defp parse(text) do
    Foreman.Config.parse_layers(
      [
        {"defaults", File.read!("priv/foreman.defaults.toml")},
        {"foreman.toml", text}
      ],
      home: "/tmp/config-home"
    )
  end

  test "local tables override global values while columns replace as a unit" do
    defaults = File.read!("priv/foreman.defaults.toml")

    global = """
    [board]
    swimlanes = "epic"
    [[repos]]
    key = "sample"
    path = "~/dev/sample"
    github = "example/sample"
    [[columns]]
    title = "Working"
    stages = ["building", "reported"]
    """

    local = """
    [board]
    stale_session_after = "30m"
    [[repos]]
    key = "sample"
    enabled = false
    """

    assert {:ok, config} =
             Foreman.Config.parse_layers(
               [{"defaults", defaults}, {"foreman.toml", global}, {"foreman.local.toml", local}],
               home: "/tmp/config-home"
             )

    assert config["board"] == %{"swimlanes" => "epic", "stale_session_after" => "30m"}
    assert config["backfill"] == %{"closed" => "done", "default" => "queued"}

    assert config["columns"] == [
             %{"title" => "Working", "stages" => ["building", "reported"], "collapsed" => false}
           ]

    assert config["repos"] == [
             %{
               "key" => "sample",
               "path" => "/tmp/config-home/dev/sample",
               "github" => "example/sample",
               "enabled" => false,
               "forge" => "github",
               "color" => "zinc",
               "tickets" => "beads"
             }
           ]
  end
end
