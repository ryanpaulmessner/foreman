defmodule ForemanWeb.DocumentsLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    root = Path.join(System.tmp_dir!(), "fm-docs-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "README.md"), "# Project\n\n[Spec](docs/spec.md)")
    File.write!(Path.join(root, "docs/spec.md"), "# Spec\n\n- [x] Complete")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config = Map.put(config, "repos", [%{"key" => "sample", "path" => root, "enabled" => true}])

    Foreman.Repo.insert_all("board_config", [
      %{id: 1, config: config, source: "test", discovered: [], loaded_at: DateTime.utc_now()}
    ])

    %{root: root}
  end

  test "draft epic shows the design pack inline and in the document viewer", %{
    conn: conn,
    root: root
  } do
    File.write!(
      Path.join(root, "docs/design.md"),
      "# Design pack\n\n## Database\n\n```mermaid\nerDiagram\n USER ||--o{ POST : writes\n```\n\n## Approval\n\n```mermaid\nsequenceDiagram\n Ryan->>Board: Approve\n```\n"
    )

    key = {"sample", "draft:pack"}
    Foreman.Overlay.apply_event(key, {:create, %{title: "Pack"}})
    Foreman.Overlay.apply_event(key, :start_spec)

    Foreman.Overlay.apply_event(
      key,
      {:approve_spec, %{spec_link: "docs/spec.md", design_link: "docs/design.md"}}
    )

    {:ok, view, _} = live(conn, "/epics/sample/draft:pack")
    assert has_element?(view, "#epic-design-link", "Design")
    assert has_element?(view, "#epic-spec-link", "Spec")
    assert has_element?(view, "#epic-design h2", "Database")
    assert has_element?(view, "#epic-design h2", "Approval")
    assert has_element?(view, "#epic-design [phx-hook=Mermaid] pre", "erDiagram")
    assert has_element?(view, "#epic-design [phx-hook=Mermaid] pre", "sequenceDiagram")
    {:ok, viewer, _} = live(conn, Foreman.Markdown.viewer_path("sample", "docs/design.md"))
    assert has_element?(viewer, "#document-content [phx-hook=Mermaid] pre", "erDiagram")
  end

  test "recorded design files use the same removed-worktree fallback as specs", %{
    conn: conn,
    root: root
  } do
    File.write!(
      Path.join(root, "docs/design.md"),
      "# Design\n\n```mermaid\ngraph TD\n A --> B\n```\n"
    )

    old = root <> "-removed/docs/design.md"
    key = {"sample", "draft:removed-design"}
    Foreman.Overlay.apply_event(key, {:create, %{title: "Design"}})
    Foreman.Overlay.apply_event(key, :start_spec)
    Foreman.Overlay.apply_event(key, {:approve_spec, %{design_link: old}})
    {:ok, view, _} = live(conn, Foreman.Markdown.viewer_path("sample", old))
    assert has_element?(view, "#document-content [phx-hook=Mermaid] pre", "A --> B")
    {:ok, epic, _} = live(conn, "/epics/sample/draft:removed-design")
    assert has_element?(epic, "#epic-design [phx-hook=Mermaid] pre", "A --> B")
    File.rm!(Path.join(root, "docs/design.md"))
    send(epic.pid, :reconcile)
    assert has_element?(epic, "#epic-design", "Design file unavailable.")
  end

  test "draft spec links still support external URLs", %{conn: conn} do
    Foreman.Overlay.apply_event(
      {"sample", "draft:external"},
      {:create, %{title: "External", spec_link: "https://example.com/spec.md"}}
    )

    {:ok, view, _} = live(conn, "/epics/sample/draft:external")
    assert has_element?(view, "#epic-spec-link[href='https://example.com/spec.md']", "Spec")
    refute has_element?(view, "#epic-design")
  end

  test "recorded artifacts survive a removed and pruned worktree", %{conn: conn, root: root} do
    old = root <> "-removed/docs/spec.md"

    Foreman.Overlay.apply_event(
      {"sample", "draft:docs"},
      {:create, %{title: "Docs", spec_link: old}}
    )

    {:ok, view, _} = live(conn, Foreman.Markdown.viewer_path("sample", old))
    assert has_element?(view, "#document-content h1", "Spec")
    render_patch(view, Foreman.Markdown.viewer_path("sample", root <> "-unknown/docs/spec.md"))
    assert has_element?(view, "#document-status", "Document unavailable")
  end

  test "project viewer lists documents and renders the selected path", %{conn: conn} do
    {:ok, view, _} = live(conn, "/documents/sample")
    assert has_element?(view, "#document-content h1", "Project")
    assert has_element?(view, "#document-files a", "docs/spec.md")
    assert has_element?(view, "#document-content a[href='/documents/sample?path=docs%2Fspec.md']")
    view |> element("#document-files a", "docs/spec.md") |> render_click()
    assert has_element?(view, "#document-content input[type=checkbox][disabled][checked]")
    assert_patch(view, "/documents/sample?path=docs%2Fspec.md")
    render_patch(view, "/documents/sample?path=..%2Fsecret.md")
    assert has_element?(view, "#document-status", "Document unavailable")
    refute has_element?(view, "#document-content")
  end
end
