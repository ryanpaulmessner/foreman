defmodule Foreman.AnswerCLI do
  @moduledoc "Parses saved-answer commands; body bytes travel in the envelope, not a file path."
  @switches [
    question: :string,
    body_file: :string,
    update: :string,
    repo: :string,
    ticket: :string,
    link: :keep,
    actor: :string,
    session: :string,
    json: :boolean
  ]

  def parse(args, defaults) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    with true <- rest == [] and invalid == [],
         true <- is_binary(opts[:body_file]),
         {:ok, body} <- File.read(opts[:body_file]),
         true <- String.valid?(body) and String.trim(body) != "" and byte_size(body) <= 1_048_576,
         true <- valid_identity?(opts) do
      attrs =
        opts
        |> Keyword.take([:question, :repo, :ticket])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      attrs =
        Map.merge(attrs, %{
          "body" => body,
          "actor" => opts[:actor] || defaults[:actor] || System.get_env("FOREMAN_ACTOR", "user"),
          "session" => opts[:session] || defaults[:session] || System.get_env("FOREMAN_SESSION")
        })

      attrs =
        if Keyword.has_key?(opts, :link),
          do:
            Map.put(
              attrs,
              "links",
              Enum.map(
                Keyword.get_values(opts, :link),
                &link_path(&1, defaults[:cwd] || File.cwd!())
              )
            ),
          else: attrs

      {:ok,
       %{
         request: %{"action" => "answer", "update" => opts[:update], "payload" => attrs},
         json: opts[:json] || false
       }}
    else
      _ ->
        {:error,
         "answer requires --question (or --update <UUID>) and a readable, nonempty UTF-8 --body-file (up to 1 MiB)"}
    end
  end

  defp link_path(link, cwd) do
    full = Path.expand(link, cwd)

    if is_nil(URI.parse(link).scheme) and Path.type(link) == :relative and File.regular?(full),
      do: full,
      else: link
  end

  defp valid_identity?(opts) do
    if opts[:update],
      do: match?({:ok, _}, Ecto.UUID.cast(opts[:update])),
      else: is_binary(opts[:question]) and String.trim(opts[:question]) != ""
  end
end
