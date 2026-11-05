defmodule ForemanWeb.AnsiHtmlTest do
  use ExUnit.Case, async: true
  alias ForemanWeb.AnsiHtml

  defp html(text), do: text |> AnsiHtml.to_html() |> Phoenix.HTML.safe_to_string()

  describe "SGR colours" do
    for {name, input, expected} <- [
          {"16 colours: basic foreground", "\e[31mred\e[39m plain",
           ~s(<span class="bb-term-fg-1">red</span> plain)},
          {"16 colours: bright foreground", "\e[94mblue\e[0m",
           ~s(<span class="bb-term-fg-12">blue</span>)},
          {"16 colours: background", "\e[42mok\e[49m", ~s(<span class="bb-term-bg-2">ok</span>)},
          {"16 colours: bright background", "\e[101mhot\e[0m",
           ~s(<span class="bb-term-bg-9">hot</span>)},
          {"256: index below 16 uses the theme class", "\e[38;5;3mwarn\e[0m",
           ~s(<span class="bb-term-fg-3">warn</span>)},
          {"256: colour cube", "\e[38;5;141mviolet\e[0m",
           ~s[<span style="color:rgb(175,135,255)">violet</span>]},
          {"256: grey ramp background", "\e[48;5;236mgrey\e[0m",
           ~s[<span style="background-color:rgb(48,48,48)">grey</span>]},
          {"truecolor foreground", "\e[38;2;255;175;0mamber\e[0m",
           ~s[<span style="color:rgb(255,175,0)">amber</span>]},
          {"truecolor background with colon form", "\e[48:2::1:2:3mx\e[0m",
           ~s[<span style="background-color:rgb(1,2,3)">x</span>]},
          {"bold", "\e[1mbold\e[22m", ~s(<span class="bb-term-b">bold</span>)},
          {"dim", "\e[2mdim\e[22m", ~s(<span class="bb-term-d">dim</span>)},
          {"italic", "\e[3mit\e[23m", ~s(<span class="bb-term-i">it</span>)},
          {"underline", "\e[4mline\e[24m", ~s(<span class="bb-term-u">line</span>)},
          {"bold and colour in one sequence", "\e[1;32mpass\e[0m",
           ~s(<span class="bb-term-fg-2 bb-term-b">pass</span>)},
          {"reset with empty parameters", "\e[1mon\e[mfoo",
           ~s(<span class="bb-term-b">on</span>foo)},
          {"reset ends every attribute", "\e[1;4;31ma\e[0mb",
           ~s(<span class="bb-term-fg-1 bb-term-b bb-term-u">a</span>b)},
          {"39 ends only the colour", "\e[1;31ma\e[39mb\e[0m",
           ~s(<span class="bb-term-fg-1 bb-term-b">a</span><span class="bb-term-b">b</span>)},
          {"inverse with default colours", "\e[7minv\e[27m",
           ~s(<span class="bb-term-inv-fg bb-term-inv-bg">inv</span>)},
          {"inverse swaps set colours", "\e[31;7mx\e[0m",
           ~s(<span class="bb-term-inv-fg bb-term-bg-1">x</span>)},
          {"colour carries across lines", "\e[33ma\nb\e[0m",
           ~s(<span class="bb-term-fg-3">a</span>\n<span class="bb-term-fg-3">b</span>)}
        ] do
      test name do
        assert html(unquote(input)) == unquote(expected)
      end
    end
  end

  describe "OSC 8 links" do
    test "an https link becomes an anchor that opens a new tab" do
      assert html("see \e]8;;https://hexdocs.pm/x\e\\docs\e]8;;\e\\ now") ==
               ~s(see <a href="https://hexdocs.pm/x" target="_blank" rel="noopener noreferrer" class="bb-term-link">docs</a> now)
    end

    test "BEL terminators and link ids work" do
      assert html("\e]8;id=7;http://localhost:4000/a\adocs\e]8;;\a") ==
               ~s(<a href="http://localhost:4000/a" target="_blank" rel="noopener noreferrer" class="bb-term-link">docs</a>)
    end

    test "a coloured link keeps its colour" do
      assert html("\e[34m\e]8;;https://a.b/\e\\x\e]8;;\e\\\e[0m") ==
               ~s(<a href="https://a.b/" target="_blank" rel="noopener noreferrer" class="bb-term-link"><span class="bb-term-fg-4">x</span></a>)
    end

    test "unsafe schemes show the text without a link" do
      assert html("\e]8;;javascript:alert(1)\e\\click\e]8;;\e\\") == "click"
      assert html("\e]8;;file:///etc/passwd\e\\f\e]8;;\e\\") == "f"
    end

    test "quotes in a URL are escaped" do
      assert html(~s(\e]8;;https://a.b/?q="x"\e\\q\e]8;;\e\\)) =~
               ~s(href="https://a.b/?q=&quot;x&quot;")
    end
  end

  describe "unsafe input" do
    test "markup in the text is escaped" do
      assert html("<script>alert('x')</script> & \e[31m<b>\e[0m") ==
               "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; " <>
                 ~s(<span class="bb-term-fg-1">&lt;b&gt;</span>)
    end

    test "other escape sequences and control bytes are dropped" do
      assert html("a\e[2Kb\e[?25lc\e]0;title\ad\r\e(Be\x07f") == "abcdef"
    end

    test "out-of-range colours are ignored" do
      assert html("\e[38;5;999mx\e[38;2;300;0;0my\e[0m") == "xy"
    end
  end

  describe "trimming" do
    test "trailing spaces and trailing empty lines go; inner blank lines stay" do
      assert html("a   \n\nb \e[0m  \n   \n\n") == "a\n\nb"
    end

    test "trailing spaces with a background colour stay" do
      assert html("\e[42mok  \e[0m") == ~s(<span class="bb-term-bg-2">ok  </span>)
    end

    test "blank?/1 is true for a screen with only spaces and codes" do
      assert AnsiHtml.blank?("   \n\e[0m  \n\n")
      assert AnsiHtml.blank?(nil)
      refute AnsiHtml.blank?("\n$ ")
    end
  end
end
