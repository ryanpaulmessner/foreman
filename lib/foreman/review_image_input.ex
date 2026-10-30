defmodule Foreman.ReviewImageInput do
  @moduledoc "CLI image arguments and verify result.json viewport metadata."

  def expand(inputs, cwd, look_at) do
    Enum.flat_map(inputs, fn input ->
      {path, explicit} = split(input)
      path = Path.expand(path, cwd)

      if File.dir?(path) do
        metadata = metadata(path)

        Path.wildcard(Path.join(path, "*.png"))
        |> Enum.map(fn file ->
          image(file, Map.get(metadata, file, %{}), look_at)
        end)
      else
        image = Map.merge(Map.get(metadata(Path.dirname(path)), path, %{}), explicit)
        [image(path, image, look_at)]
      end
    end)
  end

  defp split(input) do
    case Regex.run(~r/\A(.+)@(\d+)x(\d+):(light|dark)\z/, input) do
      [_, path, width, height, theme] ->
        {path,
         %{
           "width" => String.to_integer(width),
           "height" => String.to_integer(height),
           "theme" => theme
         }}

      _ ->
        {input, %{}}
    end
  end

  defp image(path, metadata, look_at) do
    dimensions(path)
    |> Map.merge(metadata)
    |> Map.put("path", path)
    |> Map.put("look_at", look_at)
    |> Map.reject(fn {_, value} -> is_nil(value) end)
  end

  defp dimensions(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 24)) do
      {:ok, <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32>>} ->
        %{"width" => width, "height" => height}

      _ ->
        %{}
    end
  end

  defp metadata(root) do
    with {:ok, %{size: size}} when size <= 10_000_000 <- File.stat(Path.join(root, "result.json")),
         {:ok, bytes} <- File.read(Path.join(root, "result.json")),
         {:ok, %{"pages" => pages}} when is_list(pages) <- Jason.decode(bytes) do
      for %{"screenshot" => path} = page <- pages, is_binary(path), into: %{} do
        viewport = if is_map(page["viewport"]), do: page["viewport"], else: %{}

        {Path.expand(path, root),
         Map.take(viewport, ["width", "height"]) |> Map.put("theme", page["theme"])}
      end
    else
      _ -> %{}
    end
  end
end
