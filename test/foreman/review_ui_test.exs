defmodule Foreman.ReviewUITest do
  use Foreman.DataCase, async: false
  alias Foreman.{Overlay, Requests}

  setup do
    Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])
    :ok
  end

  test "image facts retain viewport, theme and look-at; outside and traversal paths are refused" do
    root = Foreman.ScratchDocs.dir("review-images")
    File.mkdir_p!(root)

    File.write!(
      root <> "/screen.png",
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 0, 0, 5, 160, 0, 0, 3, 132>>
    )

    File.write!(root <> "/fake.png", "not an image")
    File.ln_s!(root <> "/screen.png", root <> "/link.png")
    on_exit(fn -> File.rm_rf!(root) end)
    Foreman.ScratchDocs.configure(%{"sample" => root})

    facts = %{
      "question" => "Check?",
      "images" => [
        %{
          "path" => root <> "/screen.png",
          "width" => 1440,
          "height" => 900,
          "theme" => "dark",
          "look_at" => "Header spacing"
        }
      ]
    }

    assert {:ok, request} = Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => facts})
    assert request.facts["images"] == facts["images"]

    for path <- [
          root <> "/../screen.png",
          "/etc/passwd",
          root <> "/fake.png",
          root <> "/link.png"
        ] do
      bad = put_in(facts, ["images"], [%{"path" => path}])

      assert {:error, :invalid_image} =
               Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => bad})
    end
  end

  test "a declared scratchpad is allowed but another configured repo is not" do
    root = Foreman.ScratchDocs.dir("review-scratch")
    File.mkdir_p!(root)
    path = root <> "/screen.png"
    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10, 0>>)
    on_exit(fn -> File.rm_rf!(root) end)
    Foreman.ScratchDocs.configure(%{"other" => root})
    facts = %{"question" => "Check?", "images" => [%{"path" => path}]}

    assert {:error, :invalid_image} =
             Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => facts})

    assert {:ok, _} =
             Requests.ask({"sample", "s-1"}, "review_ui", %{
               "facts" => Map.put(facts, "scratchpad", root)
             })
  end

  test "malformed optional display fields cannot create a card that crashes rendering" do
    for {field, value} <- [{"look_at", %{}}, {"text", []}, {"scratchpad", "relative/path"}] do
      facts = %{
        "question" => "Check?",
        "artifact" => "https://example.com/review",
        field => value
      }

      assert {:error, :invalid_facts} =
               Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => facts})
    end
  end

  test "review requires images or a web artifact, with fixed answer choices" do
    ask = fn facts -> Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => facts}) end
    assert {:error, :images_or_artifact_required} = ask.(%{"question" => "Check layout?"})
    assert {:error, _} = ask.(%{"question" => "Check?", "artifact" => "javascript:alert(1)"})

    assert {:ok, request} =
             ask.(%{
               "question" => "Check?",
               "artifact" => "https://example.com/review",
               "options" => ["Unsafe"]
             })

    assert request.facts["options"] == ["Looks right", "Change it"]
    assert {:error, :invalid} = Requests.resolve(request.id, :approve, %{})
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 0

    assert {:ok, %{state: "answered"}} =
             Requests.resolve(request.id, :answer, %{"answer" => "Looks right"})

    assert {:error, :invalid} = Requests.resolve(request.id, :approve, %{})
  end
end
