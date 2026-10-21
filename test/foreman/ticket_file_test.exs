defmodule Foreman.TicketFileTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Foreman.TicketFile

  def canonical(title \\ "A ticket") do
    "---\nid: bb-abc.1\ntitle: #{Jason.encode!(title)}\ntype: task\nstatus: open\npriority: 2\nparent: bb-abc\nblocked_by: []\nrelated: []\nsupersedes: []\ndiscovered_from: null\nlabels: []\ncreated: 2026-10-18\nclosed: null\nclose_reason: null\n---\n\n## Acceptance\n- [ ] Works\n"
  end

  property "canonical parse then print is byte identity, including Unicode and YAML punctuation" do
    check all(
            title <- string(:utf8, min_length: 1),
            priority <- integer(0..4),
            type <- member_of(~w(epic feature task bug decision chore)),
            status <- member_of(~w(open in_progress closed deferred)),
            labels <- list_of(string(:alphanumeric, min_length: 1), max_length: 8),
            prose <- string(:alphanumeric),
            title = "Ticket " <> title
          ) do
      text =
        canonical(title)
        |> String.replace("priority: 2", "priority: #{priority}")
        |> String.replace("type: task", "type: #{type}")
        |> String.replace("status: open", "status: #{status}")
        |> String.replace("labels: []", "labels: #{Jason.encode!(Enum.sort(labels))}")
        |> String.replace("Works", "Works #{prose}")

      assert {:ok, ticket} = TicketFile.parse(text)
      assert TicketFile.print(ticket) == text
    end
  end

  for {field, value} <- [
        {"id", "../../escape"},
        {"title", "[]"},
        {"type", "unknown"},
        {"status", "done"},
        {"priority", "5"},
        {"priority", "2.0"},
        {"parent", "false"},
        {"blocked_by", "[invalid]"},
        {"related", "no"},
        {"discovered_from", "wrong"},
        {"labels", "[false]"},
        {"created", "2026-02-30"},
        {"closed", "tomorrow"},
        {"close_reason", "[]"}
      ] do
    test "schema rejects #{field}: #{value}" do
      text =
        Regex.replace(~r/^#{unquote(field)}:.*$/m, canonical(), unquote(field <> ": " <> value))

      assert {:error, reason} = TicketFile.parse(text)
      assert reason =~ unquote(field)
    end
  end

  test "chore and supersedes survive canonical round trip; legacy files default to no supersedes" do
    text =
      canonical()
      |> String.replace("type: task", "type: chore")
      |> String.replace("supersedes: []", ~s(supersedes: ["bb-old"]))

    assert {:ok, ticket} = TicketFile.parse(text)
    assert ticket.facts["supersedes"] == ["bb-old"]
    assert TicketFile.print(ticket) == text
    assert {:ok, legacy} = TicketFile.parse(String.replace(canonical(), "supersedes: []\n", ""))
    assert legacy.facts["supersedes"] == []
  end

  test "a parked ticket carries its reason and park date; older files without them stay valid" do
    parked =
      canonical()
      |> String.replace("status: open", "status: parked")
      |> String.replace(
        "close_reason: null\n",
        "close_reason: null\nparked_reason: \"IT: VPN access\"\nparked: 2026-10-19\n"
      )

    assert {:ok, ticket} = TicketFile.parse(parked)
    assert ticket.facts["parked_reason"] == "IT: VPN access"
    assert ticket.facts["parked"] == "2026-10-19"
    assert TicketFile.print(ticket) == parked

    assert {:ok, legacy} = TicketFile.parse(canonical())
    assert TicketFile.print(legacy) == canonical()
  end

  test "kind is optional and round trips only when set" do
    assert {:ok, legacy} = TicketFile.parse(canonical())
    refute TicketFile.print(legacy) =~ "kind:"

    for kind <- ~w(break_fix mapping access feature internal) do
      text =
        String.replace(canonical(), "close_reason: null\n", "close_reason: null\nkind: #{kind}\n")

      assert {:ok, ticket} = TicketFile.parse(text)
      assert ticket.facts["kind"] == kind
      assert TicketFile.print(ticket) == text
      assert {[raw], []} = Foreman.TicketFiles.decode(%{"bb-abc.1.md" => {:ok, text}}, [])
      assert raw["kind"] == kind
    end

    assert {:error, _} =
             TicketFile.parse(
               String.replace(canonical(), "type: task", "type: task\nkind: unknown")
             )
  end

  test "parked requires a reason and a date; the fields must be valid" do
    status = String.replace(canonical(), "status: open", "status: parked")
    assert {:error, reason} = TicketFile.parse(status)
    assert reason =~ "parked_reason"

    no_date =
      String.replace(status, "close_reason: null\n", "close_reason: null\nparked_reason: \"x\"\n")

    assert {:error, reason} = TicketFile.parse(no_date)
    assert reason =~ "parked"

    bad_date =
      String.replace(no_date, "parked_reason: \"x\"\n", "parked_reason: \"x\"\nparked: soon\n")

    assert {:error, reason} = TicketFile.parse(bad_date)
    assert reason =~ "parked"
  end

  test "supersedes rejects invalid ids and non-list values" do
    for value <- ["[invalid]", "null", "false", "bb-old"] do
      assert {:error, "supersedes must be a list of ids"} =
               TicketFile.parse(
                 String.replace(canonical(), "supersedes: []", "supersedes: #{value}")
               )
    end
  end

  test "duplicate keys, multiple documents and nested mappings are invalid" do
    assert {:error, _} =
             TicketFile.parse(
               String.replace(canonical(), "priority: 2", "priority: 2\npriority: 3")
             )

    assert {:error, _} = TicketFile.parse("---\n---\nid: bb-abc\n---\n")

    assert {:error, _} =
             TicketFile.parse(
               String.replace(canonical(), "labels: []", "labels: {nested: value}")
             )
  end

  test "handwritten YAML lists and comments become sorted canonical lists" do
    text =
      canonical()
      |> String.replace("labels: []", "labels:\n  - zebra\n  - alpha # comment")
      |> String.replace("title: \"A ticket\"", "title: A ticket # comment")

    assert {:ok, ticket} = TicketFile.parse(text)
    printed = TicketFile.print(ticket)
    assert printed =~ ~s(labels: ["alpha","zebra"])
    assert printed =~ ~s(title: "A ticket")
    assert {:ok, reparsed} = TicketFile.parse(printed)
    assert TicketFile.print(reparsed) == printed
  end

  test "rejects malformed and unknown frontmatter without treating prose as YAML" do
    assert {:error, _} = TicketFile.parse("not frontmatter")

    assert {:error, _} =
             TicketFile.parse(String.replace(canonical(), "priority: 2", "priority: ["))

    assert {:error, reason} =
             TicketFile.parse(String.replace(canonical(), "priority: 2", "surprise: 2"))

    assert reason =~ "surprise"
  end
end
