defmodule Foreman.CardPanel do
  @moduledoc """
  The Needs you side panel, driven by the URL: closed, a card's ticket
  (`?ticket=repo:id`), or a document (`?doc=repo:path`). A ticket wins when
  both are present. A document that cannot be read is `unavailable`.
  """
  use Foreman.Fsm
  initial(:closed)
  state(:closed)
  state(:ticket)
  state(:document)
  state(:unavailable)
  event(:close)
  event(:ticket)
  event(:document)
  event(:missing)
  transition(:close, from: :any, to: :closed)
  transition(:ticket, from: :any, to: :ticket)
  transition(:document, from: :any, to: :document)
  transition(:missing, from: :any, to: :unavailable)

  @doc "`repo:path` from the `doc` parameter, or nil."
  def doc_key(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [repo, path] when repo != "" and path != "" -> {repo, path}
      _ -> nil
    end
  end

  def doc_key(_), do: nil

  @doc "The `doc` parameter for a viewer link (`/documents/<repo>?path=...`), or nil."
  def doc_param(href) when is_binary(href) do
    uri = URI.parse(href)

    with "/documents/" <> repo when repo != "" <- uri.path,
         false <- String.contains?(repo, "/"),
         %{"path" => path} when path != "" <- URI.decode_query(uri.query || "") do
      URI.decode(repo) <> ":" <> path
    else
      _ -> nil
    end
  end

  def doc_param(_), do: nil
end
