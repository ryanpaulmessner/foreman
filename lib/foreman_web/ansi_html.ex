defmodule ForemanWeb.AnsiHtml do
  @moduledoc """
  The board's ANSI-to-HTML converter for `tmux capture-pane -p -e` output (spec Decision 14).

  `capture-pane -e` emits only SGR (`ESC[…m`) and OSC 8 hyperlinks; every other escape
  sequence and control byte is dropped. Colours 0-15 become `bb-term-fg-N` and
  `bb-term-bg-N` classes, which the stylesheet maps to theme tokens; 256-colour indexes
  16-255 and truecolor become `rgb()` inline styles. OSC 8 links become anchors for
  http, https and mailto only. All text is HTML-escaped. Trailing spaces with the default
  background and trailing empty lines are trimmed.
  """

  @sequence ~r/\e\[[0-9;:]*m|\e\]8;[^;\e\a]*;[^\e\a]*(?:\e\\|\a)|\e\[[0-9;:<=>?]*[ -\/]*[@-~]|\e\][^\e\a]*(?:\e\\|\a)|\e[ -\/]*[0-~]?/
  @controls ~r/[\x00-\x08\x0b-\x1f\x7f]/
  @cube [0, 95, 135, 175, 215, 255]
  @plain %{fg: nil, bg: nil, b: false, d: false, i: false, u: false, s: false, inv: false}
  @link_schemes ~w(http https mailto)

  @doc "The capture as safe HTML for a `<pre>`: spans per style run, anchors for links."
  def to_html(text) when is_binary(text) do
    {:safe, text |> lines() |> Enum.map(&line_html/1) |> Enum.intersperse("\n")}
  end

  def to_html(_), do: {:safe, []}

  @doc "Whether the capture has no visible text."
  def blank?(text) when is_binary(text), do: lines(text) == []
  def blank?(_), do: true

  # Each line is a list of {style, link, text} runs, after trimming.
  defp lines(text) do
    {lines, current, _style, _link} =
      Regex.split(@sequence, text, include_captures: true, trim: true)
      |> Enum.reduce({[], [], @plain, nil}, &token/2)

    # Lines and each line's runs are newest first, so both trims work from the head.
    [current | lines]
    |> Enum.map(&(&1 |> trim_end() |> Enum.reverse()))
    |> Enum.drop_while(&(&1 == []))
    |> Enum.reverse()
  end

  defp token("\e[" <> rest, {lines, current, style, link}) do
    if Regex.match?(~r/\A[0-9;:]*m\z/, rest),
      do: {lines, current, sgr(String.trim_trailing(rest, "m"), style), link},
      else: {lines, current, style, link}
  end

  defp token("\e]8;" <> rest, {lines, current, style, _link}) do
    [_params, uri] = String.split(rest, ";", parts: 2)
    uri = uri |> String.trim_trailing("\e\\") |> String.trim_trailing("\a")
    {lines, current, style, safe_link(uri)}
  end

  defp token("\e" <> _, acc), do: acc

  defp token(text, {lines, current, style, link}) do
    [first | rest] = text |> String.replace(@controls, "", global: true) |> String.split("\n")
    current = add_run(current, style, link, first)

    Enum.reduce(rest, {lines, current}, fn part, {lines, current} ->
      {[current | lines], add_run([], style, link, part)}
    end)
    |> then(fn {lines, current} -> {lines, current, style, link} end)
  end

  defp add_run(current, _style, _link, ""), do: current
  defp add_run(current, style, link, text), do: [{style, link, text} | current]

  defp safe_link(""), do: nil

  defp safe_link(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme} when scheme in @link_schemes -> uri
      _ -> nil
    end
  end

  # Trailing whitespace with the default background is screen padding, not output.
  defp trim_end([{style, link, text} | rest]) do
    if painted?(style) do
      [{style, link, text} | rest]
    else
      case String.trim_trailing(text, " ") |> String.trim_trailing("\t") do
        "" -> trim_end(rest)
        trimmed when trimmed == text -> [{style, link, text} | rest]
        trimmed -> trim_end([{style, link, trimmed} | rest])
      end
    end
  end

  defp trim_end([]), do: []

  defp painted?(%{bg: bg, inv: inv, u: u, s: s}), do: bg != nil or inv or u or s

  defp sgr("", style), do: sgr("0", style)

  defp sgr(params, style) do
    params
    |> String.split(";")
    |> apply_params(style)
  end

  defp apply_params([], style), do: style

  defp apply_params([param | rest], style) do
    if String.contains?(param, ":") do
      apply_params(rest, colon(String.split(param, ":"), style))
    else
      case Integer.parse(param) do
        {code, ""} -> extended(code, rest, style)
        _ -> apply_params(rest, style)
      end
    end
  end

  defp extended(code, ["5", n | rest], style) when code in [38, 48],
    do: apply_params(rest, set(style, code, indexed(n)))

  defp extended(code, ["2", r, g, b | rest], style) when code in [38, 48],
    do: apply_params(rest, set(style, code, rgb([r, g, b])))

  # A malformed extended colour makes the rest of the sequence unreadable.
  defp extended(code, _rest, style) when code in [38, 48], do: style
  defp extended(code, rest, style), do: apply_params(rest, attribute(code, style))

  defp colon([code, "5", n], style) when code in ["38", "48"],
    do: set(style, String.to_integer(code), indexed(n))

  defp colon([code, "2" | values], style) when code in ["38", "48"] and length(values) in [3, 4],
    do: set(style, String.to_integer(code), rgb(Enum.take(values, -3)))

  defp colon(["4", "0"], style), do: %{style | u: false}
  defp colon(["4", _], style), do: %{style | u: true}
  defp colon(_, style), do: style

  defp set(style, _code, nil), do: style
  defp set(style, 38, colour), do: %{style | fg: colour}
  defp set(style, 48, colour), do: %{style | bg: colour}

  defp indexed(n) do
    case Integer.parse(n) do
      {n, ""} when n in 0..15 -> {:index, n}
      {n, ""} when n in 16..231 -> cube(n - 16)
      {n, ""} when n in 232..255 -> {:rgb, List.duplicate(8 + 10 * (n - 232), 3)}
      _ -> nil
    end
  end

  defp cube(n),
    do: {:rgb, Enum.map([div(n, 36), div(rem(n, 36), 6), rem(n, 6)], &Enum.at(@cube, &1))}

  defp rgb(values) do
    values = Enum.map(values, &Integer.parse/1)

    if Enum.all?(values, &match?({n, ""} when n in 0..255, &1)),
      do: {:rgb, Enum.map(values, &elem(&1, 0))}
  end

  defp attribute(0, _style), do: @plain
  defp attribute(1, style), do: %{style | b: true}
  defp attribute(2, style), do: %{style | d: true}
  defp attribute(3, style), do: %{style | i: true}
  defp attribute(4, style), do: %{style | u: true}
  defp attribute(7, style), do: %{style | inv: true}
  defp attribute(9, style), do: %{style | s: true}
  defp attribute(22, style), do: %{style | b: false, d: false}
  defp attribute(23, style), do: %{style | i: false}
  defp attribute(24, style), do: %{style | u: false}
  defp attribute(27, style), do: %{style | inv: false}
  defp attribute(29, style), do: %{style | s: false}
  defp attribute(39, style), do: %{style | fg: nil}
  defp attribute(49, style), do: %{style | bg: nil}
  defp attribute(code, style) when code in 30..37, do: %{style | fg: {:index, code - 30}}
  defp attribute(code, style) when code in 40..47, do: %{style | bg: {:index, code - 40}}
  defp attribute(code, style) when code in 90..97, do: %{style | fg: {:index, code - 82}}
  defp attribute(code, style) when code in 100..107, do: %{style | bg: {:index, code - 92}}
  defp attribute(_, style), do: style

  defp line_html(runs) do
    runs
    |> Enum.chunk_by(fn {_, link, _} -> link end)
    |> Enum.map(fn [{_, link, _} | _] = chunk ->
      body = Enum.map(chunk, fn {style, _, text} -> span(style, text) end)

      if link,
        do: [
          ~s(<a href="),
          escape(link),
          ~s(" target="_blank" rel="noopener noreferrer" class="bb-term-link">),
          body,
          "</a>"
        ],
        else: body
    end)
  end

  defp span(style, text) do
    {fg, bg} =
      if style.inv, do: {style.bg || :inv_fg, style.fg || :inv_bg}, else: {style.fg, style.bg}

    classes =
      [
        colour_class("fg", fg),
        colour_class("bg", bg),
        style.b && "bb-term-b",
        style.d && "bb-term-d",
        style.i && "bb-term-i",
        style.u && "bb-term-u",
        style.s && "bb-term-s"
      ]
      |> Enum.filter(& &1)

    styles = Enum.filter([colour_style("color", fg), colour_style("background-color", bg)], & &1)

    case {classes, styles} do
      {[], []} ->
        escape(text)

      _ ->
        [
          "<span",
          if(classes != [], do: [~s( class="), Enum.join(classes, " "), ~s(")], else: []),
          if(styles != [], do: [~s( style="), Enum.join(styles, ";"), ~s(")], else: []),
          ">",
          escape(text),
          "</span>"
        ]
    end
  end

  defp colour_class(_, :inv_fg), do: "bb-term-inv-fg"
  defp colour_class(_, :inv_bg), do: "bb-term-inv-bg"
  defp colour_class(layer, {:index, n}), do: "bb-term-#{layer}-#{n}"
  defp colour_class(_, _), do: nil

  defp colour_style(property, {:rgb, [r, g, b]}), do: "#{property}:rgb(#{r},#{g},#{b})"
  defp colour_style(_, _), do: nil

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
