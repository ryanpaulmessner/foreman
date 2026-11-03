defmodule ForemanWeb.SharedPartsTest do
  use ExUnit.Case, async: true
  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp text(document, selector), do: document |> LazyHTML.query(selector) |> LazyHTML.text()
  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  defp attr_of(document, selector, name),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  describe "status_line" do
    defp line(kind, extra \\ %{}) do
      assigns = Map.merge(%{kind: kind, id: "line"}, extra)

      ~H"""
      <ForemanWeb.StatusLine.status_line {assigns}>
        Your answer was not sent.
      </ForemanWeb.StatusLine.status_line>
      """
      |> rendered_to_string()
      |> doc()
    end

    test "each kind has its own style and its own icon" do
      icons =
        for {kind, icon} <- [
              success: "hero-check-circle",
              error: "hero-exclamation-triangle",
              info: "hero-information-circle"
            ] do
          document = line(kind)
          assert count(document, "#line.bb-status.bb-status-#{kind}") == 1
          assert count(document, "#line .#{icon}") == 1
          assert text(document, "#line") =~ "Your answer was not sent."
          icon
        end

      assert length(Enum.uniq(icons)) == 3
    end

    test "errors are alerts; success and info are polite status lines" do
      assert attr_of(line(:error), "#line", "role") == ["alert"]
      assert attr_of(line(:success), "#line", "role") == ["status"]
      assert attr_of(line(:info), "#line", "role") == ["status"]
    end

    test "Try again shows only on an error that can be retried" do
      retry = %{retry: "retry", retry_id: "line-retry"}
      assert text(line(:error, retry), "#line-retry") =~ "Try again"
      assert attr_of(line(:error, retry), "#line-retry", "phx-click") == ["retry"]
      assert count(line(:error), "button") == 0
      assert count(line(:info, retry), "button") == 0
      assert count(line(:success, retry), "button") == 0
    end
  end

  describe "flash group" do
    test "info and error flashes use the info and error lines, with different icons" do
      document =
        render_component(&ForemanWeb.Layouts.flash_group/1,
          flash: %{"info" => "Reload requested", "error" => "Request not updated"}
        )
        |> doc()

      assert text(document, "#flash-info.bb-status-info") =~ "Reload requested"
      assert text(document, "#flash-error.bb-status-error") =~ "Request not updated"
      assert count(document, "#flash-info .hero-information-circle") == 1
      assert count(document, "#flash-error .hero-exclamation-triangle") == 1
      assert attr_of(document, "#flash-error", "role") == ["alert"]
      refute count(document, ".bb-panel") > 0
    end
  end

  describe "copy_field" do
    defp copy(value) do
      assigns = %{value: value}

      ~H"""
      <ForemanWeb.CopyField.copy_field id="attach" value={@value} label="Attach command" />
      """
      |> rendered_to_string()
      |> doc()
    end

    test "a read-only mono field and a Copy button on the shared hook" do
      document = copy("tmux attach -t 'a b'")
      assert attr_of(document, "#attach", "phx-hook") == ["CopyField"]
      assert attr_of(document, "#attach input", "readonly") == [""]
      assert attr_of(document, "#attach input", "value") == ["tmux attach -t 'a b'"]
      assert attr_of(document, "#attach input", "aria-label") == ["Attach command"]
      assert attr_of(document, "#attach input", "class") |> hd() =~ "font-mono"
      assert text(document, "#attach-button .bb-copy-idle") =~ "Copy"
      assert text(document, "#attach-button .bb-copy-done") =~ "Copied"
      assert count(document, "#attach-button .bb-copy-done .hero-check") == 1
      assert attr_of(document, "#attach", "phx-mounted") |> hd() =~ "data-copied"
    end
  end

  describe "path" do
    defp path(value) do
      assigns = %{value: value}

      ~H"""
      <ForemanWeb.LongText.path id="p" text={@value} />
      """
      |> rendered_to_string()
    end

    test "a break opportunity follows each slash; nothing breaks words anywhere" do
      html = path("/srv/ryan/dev/fix-branches/query")
      parts = doc(html) |> LazyHTML.query("#p.bb-path > .bb-path-part")
      assert Enum.map(parts, &LazyHTML.text/1) == ~w(/ srv/ ryan/ dev/ fix-branches/ query)
      assert length(String.split(html, "<wbr>")) == 6
      refute html =~ "break-all"
      assert text(doc(html), "#p") == "/srv/ryan/dev/fix-branches/query"
    end

    test "text is escaped and empty values render nothing" do
      assert path("<b>/x") =~ "&lt;b&gt;/</span><wbr>"
      refute path(nil) =~ "<wbr>"
    end
  end
end
