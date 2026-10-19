defmodule Foreman.CardTextTest do
  use ExUnit.Case, async: true
  alias Foreman.CardText

  setup do
    base = Foreman.ScratchDocs.dir("card-text")
    root = Path.join(base, "repo")
    other = Path.join(base, "other")
    File.mkdir_p!(Path.join(root, "slices/one/reviews"))
    File.mkdir_p!(Path.join(other, "docs/specs"))
    File.write!(Path.join(root, "slices/one/reviews/27-r1.md"), "# Review")
    File.write!(Path.join(root, "README.md"), "# Readme")
    File.write!(Path.join(root, "notes.txt"), "not markdown")
    File.write!(Path.join(other, "docs/specs/env.md"), "# Env")
    File.write!(Path.join(base, "outside.md"), "# Outside")
    on_exit(fn -> File.rm_rf!(base) end)

    repos = [%{"key" => "sample", "path" => root}, %{"key" => "other", "path" => other}]
    %{root: root, other: other, base: base, repos: repos}
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp hrefs(html), do: doc(html) |> LazyHTML.query("a") |> LazyHTML.attribute("href")

  describe "render/3 Markdown" do
    test "keeps paragraphs, lists, emphasis, code and tables", %{repos: repos} do
      html =
        CardText.render(
          """
          First paragraph with **bold**.

          Second paragraph:
          - Commit now
          - Hold

          `code` and

          | A | B |
          | - | - |
          | 1 | 2 |
          """,
          "sample",
          repos
        )

      assert length(LazyHTML.to_tree(LazyHTML.query(doc(html), "p"))) >= 2
      assert LazyHTML.query(doc(html), "li") |> LazyHTML.to_tree() |> length() == 2
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<code>code</code>"
      assert html =~ "<table>"
    end

    test "never passes raw HTML or unsafe links through", %{repos: repos} do
      html =
        CardText.render(
          "<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[x](javascript:alert(1)) <b onclick=x>b</b>",
          "sample",
          repos
        )

      refute html =~ "<script"
      refute html =~ "<img"
      refute html =~ "onclick"
      refute html =~ "javascript:"
    end

    test "headings carry no ids that could collide with page elements", %{repos: repos} do
      html = CardText.render("# pending-requests", "sample", repos)
      refute html =~ "id="
    end
  end

  describe "detected paths" do
    test "an existing repo path becomes a viewer link, a missing one stays text", %{repos: repos} do
      html =
        CardText.render(
          "See slices/one/reviews/27-r1.md:12 and slices/one/reviews/99.md, also `README.md`.",
          "sample",
          repos
        )

      assert hrefs(html) == [
               "/documents/sample?path=slices%2Fone%2Freviews%2F27-r1.md",
               "/documents/sample?path=README.md"
             ]

      assert html =~ ">slices/one/reviews/27-r1.md:12</a>"
      assert html =~ "slices/one/reviews/99.md"
    end

    test "absolute paths link to the configured repo that holds them", %{
      repos: repos,
      other: other,
      base: base
    } do
      html =
        CardText.render(
          "Spec #{other}/docs/specs/env.md; not #{base}/outside.md",
          "sample",
          repos
        )

      assert hrefs(html) == ["/documents/other?path=docs%2Fspecs%2Fenv.md"]
    end

    test "relative paths fall back to other repos when the card's repo lacks them", %{
      repos: repos
    } do
      assert hrefs(CardText.render("docs/specs/env.md", "__foreman__", repos)) == [
               "/documents/other?path=docs%2Fspecs%2Fenv.md"
             ]
    end

    test "traversal, non-Markdown files and code blocks are not linked", %{repos: repos} do
      html =
        CardText.render(
          "../repo/README.md notes.txt\n\n```\nslices/one/reviews/27-r1.md\n```",
          "sample",
          repos
        )

      assert hrefs(html) == []
    end

    test "only the first 50 distinct paths are looked up", %{repos: repos, root: root} do
      paths = for n <- 1..60, do: "many/#{n}.md"
      for path <- paths, do: Foreman.ScratchDocs.write(root, %{path => "# x"})
      assert length(hrefs(CardText.render(Enum.join(paths, " "), "sample", repos))) == 50
    end

    test "paths inside an existing link are left alone", %{repos: repos} do
      html = CardText.render("[the review](https://example.com/README.md)", "sample", repos)
      assert hrefs(html) == ["https://example.com/README.md"]
    end
  end

  describe "docs/2 (--doc)" do
    test "repo-relative and absolute paths resolve to {repo, path}", %{
      repos: repos,
      other: other
    } do
      assert {:ok,
              [
                %{"repo" => "sample", "path" => "slices/one/reviews/27-r1.md"},
                %{"repo" => "other", "path" => "docs/specs/env.md"}
              ]} =
               CardText.docs(
                 ["slices/one/reviews/27-r1.md", other <> "/docs/specs/env.md"],
                 "sample",
                 repos
               )
    end

    test "paths outside configured repos, missing files and non-Markdown are refused", %{
      repos: repos,
      base: base
    } do
      for path <- [base <> "/outside.md", "slices/missing.md", "notes.txt", "../outside.md"] do
        assert {:error, :invalid_doc} = CardText.docs([path], "sample", repos), path
      end

      assert {:error, :invalid_doc} = CardText.docs([1], "sample", repos)

      assert {:error, :invalid_doc} =
               CardText.docs(List.duplicate("README.md", 21), "sample", repos)

      assert {:ok, []} = CardText.docs(nil, "sample", repos)
    end
  end

  test "long?/1 flags text that needs Show more" do
    refute CardText.long?("short question?")
    assert CardText.long?(Enum.map_join(1..10, "\n", &"line #{&1}"))
    assert CardText.long?(String.duplicate("word ", 200))
  end
end
