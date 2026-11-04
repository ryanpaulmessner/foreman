defmodule ForemanWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ForemanWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ForemanWeb.Endpoint

      use ForemanWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ForemanWeb.ConnCase
    end
  end

  def open_from_drawer(view, id) do
    import Phoenix.LiveViewTest
    view |> element("#needs-you-badge") |> render_click()
    refute has_element?(view, "#request-drawer form")
    view |> element("#drawer-open-#{id}") |> render_click()
    path = assert_patch(view)
    assert URI.decode_query(URI.parse(path).query)["card"] == id
    assert has_element?(view, "#needs-you-badge[aria-expanded=false]")
    view
  end

  setup tags do
    unless tags[:production_token_clock], do: ForemanWeb.LiveViewClock.install()
    if Application.get_env(:foreman, :start_repo, true), do: Foreman.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
