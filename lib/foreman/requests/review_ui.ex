defmodule Foreman.Requests.ReviewUI do
  @moduledoc "Visual review facts; answers never execute external work."
  @behaviour Foreman.Requests.Kind
  alias Foreman.Requests.Decision

  @impl true
  def validate(facts, row) when is_map(facts) do
    cond do
      not Decision.text?(facts["question"]) or not optional_fields?(facts) ->
        {:error, :invalid_facts}

      not artifact?(facts["artifact"]) ->
        {:error, :invalid_artifact}

      not images?(Map.get(facts, "images", []), row.repo_key, facts) ->
        {:error, :invalid_image}

      Map.get(facts, "images", []) == [] and is_nil(facts["artifact"]) ->
        {:error, :images_or_artifact_required}

      true ->
        {:ok,
         facts
         |> Map.take(~w(question text artifact images look_at scratchpad))
         |> Map.put_new("images", [])
         |> Map.put("options", ["Looks right", "Change it"])}
    end
  end

  def validate(_, _), do: {:error, :invalid_facts}

  defp optional_fields?(facts) do
    Enum.all?(["text", "look_at"], &(is_nil(facts[&1]) or Decision.text?(facts[&1]))) and
      (is_nil(facts["scratchpad"]) or
         (is_binary(facts["scratchpad"]) and Path.type(facts["scratchpad"]) == :absolute and
            ".." not in Path.split(facts["scratchpad"])))
  end

  defp images?(images, repo, facts) when is_list(images) and length(images) <= 60 do
    Enum.all?(images, fn
      %{"path" => path} = image ->
        Enum.all?(
          ["width", "height"],
          &(is_nil(image[&1]) or (is_integer(image[&1]) and image[&1] > 0))
        ) and
          image["theme"] in [nil, "light", "dark"] and
          (is_nil(image["look_at"]) or Decision.text?(image["look_at"])) and
          match?({:ok, _, _}, Foreman.ReviewImages.read_path(path, repo, facts["scratchpad"]))

      _ ->
        false
    end)
  end

  defp images?(_, _, _), do: false

  defp artifact?(nil), do: true

  defp artifact?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo)
  end

  defp artifact?(_), do: false

  def answer(request, payload) do
    comments = payload["image_comments"] || %{}

    if payload["answer"] in ["Looks right", "Change it"] and is_map(comments) and
         Enum.all?(comments, fn {_, text} -> is_binary(text) and byte_size(text) <= 2000 end) and
         (is_nil(payload["note"]) or is_binary(payload["note"])) do
      lines =
        (request.facts["images"] || [])
        |> Enum.with_index()
        |> Enum.flat_map(fn {image, index} ->
          case comments[to_string(index)] do
            nil ->
              []

            text ->
              if String.trim(text) == "",
                do: [],
                else: [image["path"] <> ": " <> String.trim(text)]
          end
        end)

      note = Enum.reject([payload["note"] | lines], &(&1 in [nil, ""])) |> Enum.join("\n")

      if byte_size(note) <= 20_000,
        do: {:ok, Map.put(payload, "note", note)},
        else: {:error, :invalid_note}
    else
      {:error, :invalid_answer}
    end
  end

  @impl true
  def enqueue(_), do: {:error, :review_not_executable}
end
