defmodule Foreman.MarkdownTest do
  use ExUnit.Case, async: true

  test "mermaid source is preserved as inert text in a diagram hook" do
    source = "graph TD\n A[\"<script>alert(1)</script>\"] --> B\n"
    html = Foreman.Markdown.render("```mermaid\n" <> source <> "```\n")
    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, "[phx-hook=Mermaid] pre") |> LazyHTML.text() == source
    assert LazyHTML.query(doc, "script") |> LazyHTML.to_tree() == []
    assert html =~ "phx-update=\"ignore\""
  end

  test "twelve mermaid diagrams each retain their own source exactly once" do
    sources = Enum.map(0..11, &"graph TD\n Node#{&1} --> End#{&1}\n")
    markdown = Enum.map_join(sources, "\n", &("```mermaid\n" <> &1 <> "```\n"))
    doc = markdown |> Foreman.Markdown.render() |> LazyHTML.from_fragment()

    assert length(LazyHTML.query(doc, "div.fm-diagram") |> LazyHTML.to_tree()) == 12
    assert LazyHTML.query(doc, ".fm-diagram .fm-diagram") |> LazyHTML.to_tree() == []

    for {source, index} <- Enum.with_index(sources, 1) do
      block = LazyHTML.query(doc, "div.fm-diagram:nth-of-type(#{index})")
      assert length(LazyHTML.query(block, "pre") |> LazyHTML.to_tree()) == 1
      assert LazyHTML.text(block) == source
    end
  end

  test "mermaid diagrams inside lists keep their source" do
    html = Foreman.Markdown.render("- ```mermaid\n  graph TD\n    A --> B\n  ```\n")
    assert html =~ "phx-hook=\"Mermaid\""
    assert html =~ "A --&gt; B"
  end

  test "relative Markdown links stay in the project viewer" do
    html =
      Foreman.Markdown.render(
        "[Next](../guide.md#install) [Web](https://example.com) [Escape](../../secret.md)",
        repo: "sample",
        path: "docs/design/spec.md"
      )

    assert html =~ "/documents/sample?path=docs%2Fguide.md#install"
    assert html =~ "href=\"https://example.com\""
    refute html =~ "href=\"../../"
  end

  test "relative traversal cannot be clamped back into the project" do
    html =
      Foreman.Markdown.render("[Escape](../../README.md) [Encoded](%2e%2e/%2e%2e/README.md)",
        repo: "sample",
        path: "docs/spec.md"
      )

    refute html =~ "/documents/"
  end

  test "ticket rendering refuses oversized input before parsing" do
    assert Foreman.Markdown.render(String.duplicate("x", 1_048_577)) == "<p>Content too large</p>"
  end

  test "GFM renders checkboxes, tables, footnotes, autolinks and dual-theme code, but not raw HTML" do
    html =
      Foreman.Markdown.render("""
      - [x] Shipped
      - [ ] Pending

      | Name | Status |
      | --- | --- |
      | Reader | Ready |

      Footnote[^1] https://example.com

      [^1]: Note

      ```elixir
      def hello, do: :world
      ```

      <script>alert('bad')</script>

      <img src=x onerror=alert(1)>

      [unsafe](javascript:alert%281%29)
      """)

    doc = LazyHTML.from_fragment(html)

    assert length(LazyHTML.query(doc, "input[type=checkbox][disabled]") |> LazyHTML.to_tree()) ==
             2

    assert html =~ "<table>"
    assert html =~ "footnote"
    assert html =~ "href=\"https://example.com\""
    assert html =~ "--lumis-light"
    assert html =~ "--lumis-dark"
    refute html =~ "<script"
    refute html =~ "<img"
    refute html =~ "href=\"javascript:"
  end
end
