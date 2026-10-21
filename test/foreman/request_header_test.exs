defmodule Foreman.RequestHeaderTest do
  use ExUnit.Case, async: true
  alias Foreman.RequestHeader

  test "one-off context includes the ticket title, kind and first sentence" do
    header =
      RequestHeader.build(%{
        "id" => "s-1",
        "title" => "Repair login",
        "kind" => "break_fix",
        "description" => "Login fails on mobile. More detail."
      })

    assert header.kind == "Break-fix"
    assert header.title == "Repair login"
    assert header.part_of == "One-off"
    assert header.from == "Login fails on mobile."
    assert header.summary == nil
  end

  test "nearest epic supplies part of and inherited kind" do
    epic = %{
      "id" => "s-e",
      "title" => "Mobile access",
      "issue_type" => "epic",
      "kind" => "feature"
    }

    parent = %{
      "id" => "s-p",
      "dependencies" => [%{"type" => "parent-child", "depends_on_id" => "s-e"}]
    }

    ticket = %{
      "id" => "s-1",
      "dependencies" => [%{"type" => "parent-child", "depends_on_id" => "s-p"}]
    }

    header = RequestHeader.build(ticket, [parent, epic])
    assert header.part_of == "Mobile access"
    assert header.kind == "Feature"
  end

  test "Support Board and Asana origins are explicit" do
    assert RequestHeader.build(%{"description" => "**Ticket:** T-123\nDetails"}).from ==
             "Support Board T-123"

    header =
      RequestHeader.build(%{"description" => "See https://app.asana.com/0/123/456 for details"})

    assert header.from == "Asana"
    assert header.origin_url == "https://app.asana.com/0/123/456"

    assert RequestHeader.build(%{"description" => "Asana 1234567890"}).origin_url ==
             "https://app.asana.com/0/0/1234567890"

    assert RequestHeader.build(%{}).from == nil
  end

  test "fallback skips Summary, headings and absent origins, and strips bold" do
    header =
      RequestHeader.build(%{
        "description" =>
          "## Summary\nTitle: Internal\nWhat users see: Summary.\n## Background\n**Ticket:** none\n\n**Login** fails. More."
      })

    assert header.from == "Login fails."
    assert RequestHeader.build(%{"description" => "**Ticket:** none"}).from == nil
    assert RequestHeader.build(%{"description" => "## Summary\nTitle: Only summary"}).from == nil

    assert RequestHeader.build(%{"description" => String.duplicate("x", 81)}).from ==
             String.duplicate("x", 80) <> "…"

    assert RequestHeader.build(%{"description" => String.duplicate("x", 80)}).from ==
             String.duplicate("x", 80)
  end

  test "short numbers are not Asana gids" do
    header = RequestHeader.build(%{"description" => "moved from Asana 2 weeks ago"})
    assert header.origin_url == nil
    assert header.from == "moved from Asana 2 weeks ago"
  end

  test "Summary overrides title and exposes only What users see" do
    header =
      RequestHeader.build(%{
        "title" => "Technical",
        "description" =>
          "Original request.\n\n## Summary\nTitle: Clear title\nWhat users see: Login works on mobile.\nHow it works: Cookies.\n\n## Notes\nWhat users see: Not the summary"
      })

    assert header.title == "Clear title"
    assert header.summary == "Login works on mobile."
    assert header.from == "Original request."
  end
end
