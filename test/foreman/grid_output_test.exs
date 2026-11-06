defmodule Foreman.GridOutputTest do
  use ExUnit.Case, async: true
  alias Foreman.GridOutput

  test "Claude input and status are dropped before taking the last six lines" do
    text =
      "old\none\ntwo\nthree\nfour\nfive\n\e[32msix\e[0m\n────────────────\n❯ draft message\n────────────────\n  ⏵⏵ bypass permissions on\n\n"

    assert GridOutput.excerpt(text, "claude") == "one\ntwo\nthree\nfour\nfive\n\e[32msix\e[0m"
  end

  test "Pi output keeps content that looks like a prompt" do
    assert GridOutput.excerpt("one\n❯ content\n\n", "pi") == "one\n❯ content"
  end
end
