defmodule Foreman.Markdown do
  @moduledoc """
  GFM with raw HTML omitted (MDEx's unsafe rendering remains disabled).
  Only renderer-generated highlighting styles and disabled checkboxes are emitted.
  """
  @options [
    extension: [
      header_ids: "",
      table: true,
      tasklist: true,
      strikethrough: true,
      autolink: true,
      footnotes: true
    ],
    render: [unsafe: false, escape: false],
    syntax_highlight: [
      formatter:
        {:html_multi_themes,
         themes: [light: "github_light", dark: "github_dark"], css_variable_prefix: "--lumis"}
    ]
  ]

  # A bare Markdown path, optionally with `:line` or `:start-end`.
  @path ~r{(?<![\w/.~:@-])((?:~/|/)?(?:[\w.-]+/)*[\w.-]+\.md)(:\d+(?:-\d+)?)?(?![\w/-])}u

  @doc "Paths `link_paths:` may be asked about, in order of appearance."
  def path_candidates(text) when is_binary(text),
    do: @path |> Regex.scan(text, capture: :all_but_first) |> Enum.map(&hd/1) |> Enum.uniq()

  def render(text, opts \\ [])

  def render(text, _opts) when is_binary(text) and byte_size(text) > 1_048_576,
    do: "<p>Content too large</p>"

  def render(nil, _opts), do: ""

  def render(text, opts) do
    options =
      if opts[:header_ids] == false,
        do: put_in(@options, [:extension, :header_ids], nil),
        else: @options

    document =
      text
      |> MDEx.parse_document!(options)
      |> MDEx.traverse_and_update(fn
        %MDEx.Link{url: url} = link -> %{link | url: link_url(url, opts)}
        node -> node
      end)

    document =
      if resolver = opts[:link_paths], do: link_paths(document, resolver), else: document

    MDEx.to_html!(document)
  end

  # Bare Markdown paths in text or inline code become links when `resolver`
  # returns a URL for them. Existing links and code blocks are left alone.
  defp link_paths(%MDEx.Link{} = link, _), do: link

  defp link_paths(%{nodes: nodes} = node, resolver) when is_list(nodes),
    do: %{node | nodes: Enum.flat_map(nodes, &expand(&1, resolver))}

  defp link_paths(node, _), do: node

  defp expand(%MDEx.Text{literal: literal}, resolver) do
    {nodes, rest} =
      @path
      |> Regex.scan(literal, return: :index)
      |> Enum.reduce({[], 0}, fn [{start, length}, {path_start, path_length} | _], {acc, from} ->
        case resolver.(binary_part(literal, path_start, path_length)) do
          url when is_binary(url) ->
            link = %MDEx.Link{
              url: url,
              title: "",
              nodes: [%MDEx.Text{literal: binary_part(literal, start, length)}]
            }

            {[link, text(literal, from, start) | acc], start + length}

          _ ->
            {acc, from}
        end
      end)

    Enum.reject(Enum.reverse([text(literal, rest, byte_size(literal)) | nodes]), &is_nil/1)
  end

  defp expand(%MDEx.Code{literal: literal} = code, resolver) do
    literal = String.trim(literal)

    with [^literal, path | _] <- Regex.run(@path, literal),
         url when is_binary(url) <- resolver.(path) do
      [%MDEx.Link{url: url, title: "", nodes: [code]}]
    else
      _ -> [code]
    end
  end

  defp expand(node, resolver), do: [link_paths(node, resolver)]

  defp text(_literal, from, to) when to <= from, do: nil
  defp text(literal, from, to), do: %MDEx.Text{literal: binary_part(literal, from, to - from)}

  def viewer_path(repo, path),
    do:
      "/documents/" <>
        URI.encode(repo, &URI.char_unreserved?/1) <> "?" <> URI.encode_query(%{"path" => path})

  defp relative_path(path, base) do
    if Path.type(path) == :absolute or Path.type(base) == :absolute do
      {:ok, Path.expand(path, Path.dirname(base))}
    else
      root = "/__foreman_document_root__"
      full = Path.expand(path, Path.dirname(Path.join(root, base)))

      if String.starts_with?(full, root <> "/"),
        do: {:ok, Path.relative_to(full, root)},
        else: :error
    end
  end

  defp link_url(url, opts) do
    uri = URI.parse(url)

    cond do
      uri.scheme in ["http", "https", "mailto"] ->
        url

      uri.scheme != nil or uri.host != nil ->
        ""

      is_nil(uri.path) or uri.path == "" ->
        url

      opts[:repo] && String.downcase(Path.extname(uri.path)) == ".md" ->
        case relative_path(URI.decode(uri.path), opts[:path] || "README.md") do
          {:ok, path} ->
            viewer_path(opts[:repo], path) <>
              if(uri.fragment, do: "#" <> URI.encode(uri.fragment), else: "")

          :error ->
            ""
        end

      true ->
        ""
    end
  end
end
