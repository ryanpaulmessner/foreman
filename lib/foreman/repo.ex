defmodule Foreman.Repo do
  use Ecto.Repo,
    otp_app: :foreman,
    adapter: Ecto.Adapters.Postgres

  @doc """
  True when `exception` means that the database did not answer: a lost
  connection, or a query that timed out and was cancelled.
  """
  def unavailable?(%DBConnection.ConnectionError{}), do: true
  def unavailable?(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: true
  def unavailable?(_), do: false
end
