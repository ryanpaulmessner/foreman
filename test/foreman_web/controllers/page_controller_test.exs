defmodule ForemanWeb.PageControllerTest do
  use ForemanWeb.ConnCase
  import Phoenix.LiveViewTest

  test "home opens initiatives", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#initiative-filters")
    assert has_element?(view, "nav[aria-label=Main]")
  end
end
