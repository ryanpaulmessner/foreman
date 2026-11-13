defmodule ForemanWeb.ReviewTryIt do
  @moduledoc "The walkthrough and preview on a live review card."
  use ForemanWeb, :html

  attr :request, :any, required: true
  attr :prefix, :string, default: ""

  def card(assigns) do
    assigns =
      assign(
        assigns,
        :command,
        "walkthrough play #{quote_arg(assigns.request.facts["walkthrough_path"])} --url #{quote_arg(assigns.request.facts["url"])}"
      )

    ~H"""
    <section id={@prefix <> "review-try-it-" <> @request.id} class="mb-5 space-y-4 text-sm">
      <p class="whitespace-pre-wrap break-words">{@request.facts["walkthrough"]["intro"]}</p>
      <a
        id={@prefix <> "review-preview-" <> @request.id}
        href={@request.facts["url"]}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex items-center gap-2 rounded-md border border-base px-3 py-2 font-medium transition hover:border-primary hover:text-primary"
      >
        Open preview <.icon name="hero-arrow-top-right-on-square" class="size-4" />
      </a>
      <p
        :if={Foreman.PreviewCheck.load(@request.facts) == :down}
        id={@prefix <> "review-preview-state-" <> @request.id}
        class="rounded-md border border-base bg-sunken px-3 py-2 text-foreground"
      >
        The preview is not running. Ask {@request.session || "the asking session"} to start it again.
      </p>
      <ol id={@prefix <> "review-steps-" <> @request.id} class="list-decimal space-y-3 pl-5">
        <li :for={step <- @request.facts["walkthrough"]["steps"]} class="pl-1">
          <p class="font-medium whitespace-pre-wrap break-words">{step["say"]}</p>
          <p class="mt-1 whitespace-pre-wrap break-words text-foreground-softer">{step["see"]}</p>
        </li>
      </ol>
      <video
        :if={@request.facts["video"]}
        id={@prefix <> "review-video-" <> @request.id}
        src={"/request-images/#{@request.id}/video"}
        controls
        preload="metadata"
        aria-label="Walkthrough recording"
        class="max-h-80 w-full rounded-lg border border-base bg-sunken"
      >
      </video>
      <div
        id={@prefix <> "review-play-" <> @request.id}
        phx-hook=".CopyPlay"
        class="flex min-w-0 items-center gap-2"
      >
        <div class="min-w-0 flex-1">
          <.input
            id={@prefix <> "review-play-value-" <> @request.id}
            name="play_command"
            value={@command}
            type="text"
            readonly
            aria-label="Play command"
            class="w-full min-w-0 rounded-md border border-base bg-sunken px-3 py-2 font-mono text-xs"
          />
        </div>
        <button
          id={@prefix <> "review-play-copy-" <> @request.id}
          type="button"
          class="cursor-pointer rounded-md border border-base px-3 py-2 font-medium transition hover:border-primary"
        >
          Copy
        </button>
      </div>
      <p class="text-foreground-softer">
        Ask {@request.session || "the asking session"} to walk you through it, or run the player.
      </p>
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyPlay">
      export default {
        mounted() {
          this.copy = async () => {
            const input = this.el.querySelector("input")
            try { await navigator.clipboard.writeText(input.value) }
            catch { input.focus(); input.select() }
          }
          this.el.querySelector("button").addEventListener("click", this.copy)
        },
        destroyed() { this.el.querySelector("button").removeEventListener("click", this.copy) }
      }
    </script>
    """
  end

  defp quote_arg(value), do: "'" <> String.replace(value || "", "'", "'\\''") <> "'"
end
