defmodule Foreman.TryIt do
  @moduledoc "Validation for a review's immutable walkthrough and local preview target."
  alias Foreman.Requests.Decision

  def validate(%{"url" => url} = facts, repo) when not is_nil(url) do
    cond do
      not local_url?(url) ->
        unclear("url must be http://localhost:<port> or http://127.0.0.1:<port>")

      not walkthrough?(facts["walkthrough"]) ->
        unclear("walkthrough with at least one complete step is required")

      not Decision.text?(facts["walkthrough_path"]) ->
        unclear("walkthrough path is required")

      not commit?(facts["sha"], repo) ->
        unclear("sha must be a full commit SHA in the repo")

      true ->
        :ok
    end
  end

  def validate(_, _), do: :ok

  def local_url?(url) when is_binary(url) do
    Regex.match?(~r/\Ahttp:\/\/(localhost|127\.0\.0\.1):[0-9]+\/?\z/, url) and
      URI.parse(url).port in 1..65535
  end

  def local_url?(_), do: false

  defp walkthrough?(%{"intro" => intro, "seed" => seed, "steps" => [_ | _] = steps}) do
    Decision.text?(intro) and strings?(seed) and length(steps) <= 100 and
      Enum.all?(steps, fn
        %{"say" => say, "changed" => changed, "do" => actions, "see" => see, "check" => check} ->
          Decision.text?(say) and is_binary(changed) and strings?(actions) and
            Decision.text?(see) and Decision.text?(check)

        _ ->
          false
      end)
  end

  defp walkthrough?(_), do: false
  defp strings?(items), do: is_list(items) and Enum.all?(items, &is_binary/1)

  defp commit?(sha, key) when is_binary(sha) do
    with true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
         %{"path" => path} <- Enum.find(Foreman.CardText.repos(), &(&1["key"] == key)),
         {"commit\n", 0} <-
           System.cmd("git", ["-C", path, "cat-file", "-t", sha], stderr_to_stdout: true) do
      true
    else
      _ -> false
    end
  end

  defp commit?(_, _), do: false
  defp unclear(message), do: {:error, %{error: "card_unclear", missing: [message]}}
end
