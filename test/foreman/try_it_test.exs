defmodule Foreman.TryItTest do
  use Foreman.DataCase, async: false
  alias Foreman.Requests

  setup do
    Foreman.Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])
    root = Foreman.ScratchDocs.dir("try-it")
    File.mkdir_p!(root)
    System.cmd("git", ["init", root])

    System.cmd("git", [
      "-C",
      root,
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "initial"
    ])

    {sha, 0} = System.cmd("git", ["-C", root, "rev-parse", "HEAD"])
    Foreman.ScratchDocs.configure(%{"sample" => root})
    on_exit(fn -> File.rm_rf!(root) end)

    facts = %{
      "question" => "Try it?",
      "artifact" => "https://example.com/review",
      "url" => "http://localhost:4812",
      "sha" => String.trim(sha),
      "walkthrough_path" => root <> "/walkthrough.json",
      "walkthrough" => %{
        "intro" => "Try the card.",
        "seed" => [],
        "steps" => [
          %{
            "say" => "Open it",
            "changed" => "Preview",
            "do" => ["goto /"],
            "see" => "The card",
            "check" => "#card"
          }
        ]
      }
    }

    %{facts: facts, root: root}
  end

  test "WebM is served only from declared safe paths", %{facts: facts, root: root} do
    path = root <> "/run.webm"
    File.write!(path, <<0x1A, 0x45, 0xDF, 0xA3, "webm">>)

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => Map.put(facts, "video", path)})

    assert request.facts["video"] == path
    assert {:ok, _, "video/webm"} = Foreman.ReviewImages.read(request, :video)
    File.ln_s!(path, root <> "/link.webm")

    for bad <- [root <> "/link.webm", "/etc/passwd", root <> "/../run.webm"] do
      assert {:error, :invalid_video} =
               Requests.ask({"sample", "s-1"}, "review_ui", %{
                 "facts" => Map.put(facts, "video", bad)
               })
    end
  end

  test "HTTP results update only preview facts and stop after an answer", %{facts: facts} do
    {:ok, request} = Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => facts})
    up = fn conn -> Plug.Conn.send_resp(conn, 200, "ready") end
    down = fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end
    Foreman.PreviewChecks.check(request.id, plug: up)
    checked = Requests.get(request.id)
    assert checked.state == "pending"
    assert checked.facts["preview"] == "up"
    Foreman.PreviewChecks.check(request.id, plug: down)
    assert Requests.get(request.id).facts["preview"] == "down"
    assert {:error, :invalid} = Requests.resolve(request.id, :answer, %{"answer" => "Works"})
    Foreman.PreviewChecks.check(request.id, plug: up)
    assert {:ok, answered} = Requests.resolve(request.id, :answer, %{"answer" => "Works"})
    assert answered.facts["preview"] == "stopped"
    Foreman.PreviewChecks.check(request.id, plug: fn _ -> flunk("checked a closed card") end)
    assert Requests.get(request.id).outcome == %{"answer" => "Works"}
  end

  test "a late HTTP result cannot reopen an answered review", %{facts: facts} do
    {:ok, request} = Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => facts})

    Foreman.PreviewChecks.check(request.id,
      plug: fn conn ->
        assert {:ok, _} =
                 Requests.resolve(request.id, :answer, %{
                   "answer" => "Found a problem",
                   "note" => "Wrong layout"
                 })

        Plug.Conn.send_resp(conn, 200, "ready")
      end
    )

    assert %{state: "answered", facts: %{"preview" => "stopped"}} = Requests.get(request.id)
  end

  test "checks do not follow redirects outside localhost", %{facts: facts} do
    {:ok, request} = Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => facts})

    Foreman.PreviewChecks.check(request.id,
      plug: fn conn ->
        assert conn.host == "localhost"

        conn
        |> Plug.Conn.put_resp_header("location", "https://example.invalid/private")
        |> Plug.Conn.send_resp(302, "")
      end
    )

    assert Requests.get(request.id).facts["preview"] == "up"
  end

  test "Works requires an up check; a problem requires a note and stops checking", %{facts: facts} do
    assert {:ok, request} =
             Requests.ask({"sample", "s-1"}, "review_ui", %{
               "facts" => Map.put(facts, "preview", "up")
             })

    assert request.facts["preview"] == "unchecked"
    assert {:error, :invalid} = Requests.resolve(request.id, :answer, %{"answer" => "Works"})

    assert {:error, :invalid} =
             Requests.resolve(request.id, :answer, %{"answer" => "Found a problem"})

    assert {:ok, answered} =
             Requests.resolve(request.id, :answer, %{
               "answer" => "Found a problem",
               "note" => "Button clips"
             })

    assert answered.facts["preview"] == "stopped"
    assert answered.outcome == %{"answer" => "Found a problem"}
  end

  test "URL reviews require walkthrough steps, a local URL and a known commit", %{facts: facts} do
    for bad <- [
          Map.delete(facts, "walkthrough"),
          put_in(facts, ["walkthrough", "steps"], []),
          Map.delete(facts, "sha"),
          Map.put(facts, "sha", String.duplicate("0", 40)),
          Map.put(facts, "url", "https://example.com"),
          Map.put(facts, "url", "http://localhost:4812@evil.test")
        ] do
      assert {:error, %{error: "card_unclear"}} =
               Requests.ask({"sample", "s-1"}, "review_ui", %{"facts" => bad})
    end
  end
end
