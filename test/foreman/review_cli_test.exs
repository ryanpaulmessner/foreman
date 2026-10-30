defmodule Foreman.ReviewCLITest do
  use ExUnit.Case, async: true

  test "a PNG without verify metadata carries its intrinsic dimensions" do
    root = Path.join(System.tmp_dir!(), "review-size-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    File.write!(
      root <> "/plain.png",
      <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", 820::32, 1180::32>>
    )

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, %{request: %{"facts" => %{"images" => [image]}}}} =
             Foreman.CLI.parse(["ask", "review_ui", "s-1", "--image", "plain.png"], cwd: root)

    assert image["width"] == 820
    assert image["height"] == 1180
  end

  test "review CLI expands a folder with verify metadata and accepts explicit viewports" do
    root = Path.join(System.tmp_dir!(), "review-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(root <> "/phone.png", "png")

    File.write!(
      root <> "/result.json",
      Jason.encode!(%{
        "pages" => [
          %{
            "screenshot" => root <> "/phone.png",
            "viewport" => %{"width" => 390, "height" => 844},
            "theme" => "dark"
          }
        ]
      })
    )

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, %{request: %{"facts" => facts}}} =
             Foreman.CLI.parse(
               [
                 "ask",
                 "review_ui",
                 "s-1",
                 "--question",
                 "Check?",
                 "--text",
                 "Layout",
                 "--image",
                 root,
                 "--image",
                 "desktop.png@1440x900:light",
                 "--look-at",
                 "Header",
                 "--scratchpad",
                 root,
                 "--artifact",
                 "https://example.com/review"
               ],
               cwd: root
             )

    assert facts["images"] == [
             %{
               "path" => root <> "/phone.png",
               "width" => 390,
               "height" => 844,
               "theme" => "dark",
               "look_at" => "Header"
             },
             %{
               "path" => root <> "/desktop.png",
               "width" => 1440,
               "height" => 900,
               "theme" => "light",
               "look_at" => "Header"
             }
           ]

    assert facts["scratchpad"] == root
    assert facts["artifact"] == "https://example.com/review"
  end
end
