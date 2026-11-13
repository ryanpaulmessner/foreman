defmodule ForemanWeb.ReviewImageTest do
  use ForemanWeb.ConnCase, async: false

  test "HTTP video route serves declared WebM and rechecks symlinks", %{conn: conn} do
    root = Foreman.ScratchDocs.dir("video-http")
    File.mkdir_p!(root)
    bytes = <<0x1A, 0x45, 0xDF, 0xA3, "webm">>
    path = root <> "/run.webm"
    File.write!(path, bytes)
    on_exit(fn -> File.rm_rf!(root) end)
    Foreman.ScratchDocs.configure(%{"sample" => root})

    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        actor: "pi",
        kind: "review_ui",
        state: "pending",
        facts: %{"video" => path}
      })

    url = "/request-images/#{request.id}/video"
    result = get(conn, url)
    assert response(result, 200) == bytes
    assert get_resp_header(result, "content-type") == ["video/webm"]
    assert get_resp_header(result, "x-content-type-options") == ["nosniff"]
    File.rename!(path, root <> "/actual.webm")
    File.ln_s!(root <> "/actual.webm", path)
    assert conn |> get(url) |> response(404)
  end

  test "HTTP reads only indexed raster files, and rechecks paths after posting", %{conn: conn} do
    root = Foreman.ScratchDocs.dir("image-http")
    File.mkdir_p!(root)
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0>>
    File.write!(root <> "/screen.png", bytes)
    File.write!(root <> "/secret.txt", "secret")
    on_exit(fn -> File.rm_rf!(root) end)
    Foreman.ScratchDocs.configure(%{"sample" => root})

    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        actor: "pi",
        kind: "review_ui",
        state: "pending",
        facts: %{
          "images" => [%{"path" => root <> "/screen.png"}, %{"path" => root <> "/secret.txt"}]
        }
      })

    url = "/request-images/#{request.id}/0"
    result = get(conn, url)
    assert response(result, 200) == bytes
    assert get_resp_header(result, "content-type") == ["image/png"]
    assert get_resp_header(result, "x-content-type-options") == ["nosniff"]

    for index <- ["1", "-1", "99", "bad"] do
      assert conn |> get("/request-images/#{request.id}/#{index}") |> response(404)
    end

    File.rm!(root <> "/screen.png")
    File.ln_s!(root <> "/secret.txt", root <> "/screen.png")
    assert conn |> get(url) |> response(404)
  end
end
