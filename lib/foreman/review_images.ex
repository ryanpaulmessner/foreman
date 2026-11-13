defmodule Foreman.ReviewImages do
  @moduledoc "Bounded raster image reads for a request's declared image set. No arbitrary HTTP paths."
  @max_bytes 20_000_000

  def read(request, :video) do
    read_video_path(request.facts["video"], request.repo_key, request.facts["scratchpad"])
  end

  def read(request, index) when is_integer(index) and index >= 0 do
    with %{"path" => path} <- Enum.at(request.facts["images"] || [], index) do
      read_path(path, request.repo_key, request.facts["scratchpad"])
    else
      _ -> {:error, :invalid_image}
    end
  end

  def read(_, _), do: {:error, :invalid_image}

  def read_path(path, repo, scratchpad), do: read_media(path, repo, scratchpad, :image)
  def read_video_path(path, repo, scratchpad), do: read_media(path, repo, scratchpad, :video)

  defp read_media(path, repo, scratchpad, kind) when is_binary(path) do
    max_bytes = if kind == :video, do: 100_000_000, else: @max_bytes
    roots = [repo_root(repo), Path.expand("~/.cache/verify/runs"), scratchpad]

    with false <- ".." in Path.split(path),
         true <- Path.type(path) == :absolute,
         true <-
           Enum.any?(
             roots,
             &(is_binary(&1) and String.starts_with?(path, Path.expand(&1) <> "/"))
           ),
         true <- regular?(path),
         {:ok, bytes} when is_binary(bytes) <-
           File.open(path, [:read, :binary], &IO.binread(&1, max_bytes + 1)),
         true <- byte_size(bytes) <= max_bytes,
         type when not is_nil(type) <-
           media_type(bytes, String.downcase(Path.extname(path)), kind) do
      {:ok, bytes, type}
    else
      _ -> {:error, :invalid_image}
    end
  end

  defp read_media(_, _, _, _), do: {:error, :invalid_image}

  defp media_type(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>, ".webm", :video), do: "video/webm"
  defp media_type(_, _, :video), do: nil
  defp media_type(bytes, ext, :image), do: image_type(bytes, ext)

  defp repo_root(key) do
    case Enum.find(Foreman.CardText.repos(), &(&1["key"] == key)) do
      nil -> nil
      repo -> repo["path"]
    end
  end

  defp regular?(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.all?(fn part ->
      case File.lstat(part) do
        {:ok, %{type: :directory}} -> part != path
        {:ok, %{type: :regular}} -> part == path
        _ -> false
      end
    end)
  end

  defp image_type(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>, ".png"), do: "image/png"

  defp image_type(<<255, 216, 255, _::binary>>, ext) when ext in [".jpg", ".jpeg"],
    do: "image/jpeg"

  defp image_type(<<"GIF", version::binary-size(3), _::binary>>, ".gif")
       when version in ["87a", "89a"], do: "image/gif"

  defp image_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>, ".webp"), do: "image/webp"
  defp image_type(_, _), do: nil
end
