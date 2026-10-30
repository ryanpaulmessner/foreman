defmodule Foreman.Requests.Kind do
  @moduledoc "Creation validation and transactional approval extension point. Jobs must revalidate live facts and claim once before IO."
  @callback validate(map(), map()) :: {:ok, map()} | {:error, atom() | map()}
  @callback enqueue(Foreman.Requests.Request.t()) :: :ok | {:error, atom()}

  def fetch("session_waiting"), do: {:ok, Foreman.SessionWaiting}
  def fetch("open_pr"), do: {:ok, Foreman.Requests.OpenPr}
  def fetch("merge"), do: {:ok, Foreman.Requests.Merge}
  def fetch("push"), do: {:ok, Foreman.Requests.Push}
  def fetch("review_ui"), do: {:ok, Foreman.Requests.ReviewUI}
  def fetch("decision"), do: {:ok, Foreman.Requests.Decision}
  def fetch(_), do: {:error, :unsupported_kind}
end
