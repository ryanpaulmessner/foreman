defmodule ForemanWeb.ReviewImageController do
  use ForemanWeb, :controller

  def show(conn, %{"id" => id, "index" => index}) do
    with %{kind: "review_ui"} = request <- Foreman.Requests.get(id),
         {index, ""} <- Integer.parse(index),
         {:ok, bytes, type} <- Foreman.ReviewImages.read(request, index) do
      conn
      |> put_resp_header("content-type", type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "Image unavailable")
    end
  end
end
