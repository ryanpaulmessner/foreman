defmodule ForemanWeb.ReviewImages do
  @moduledoc "Review images grouped by viewport and theme, with one comment per image."
  use ForemanWeb, :html
  attr :request, :any, required: true
  attr :prefix, :string, default: ""

  def grid(assigns) do
    groups =
      (assigns.request.facts["images"] || [])
      |> Enum.with_index()
      |> Enum.group_by(fn {image, _} -> {image["width"], image["theme"]} end)
      |> Enum.sort_by(fn {{width, theme}, _} -> {-(width || 0), theme} end)

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div id={@prefix <> "review-images-" <> @request.id} class="space-y-5">
      <a
        :if={@request.facts["artifact"]}
        id={@prefix <> "review-artifact-" <> @request.id}
        href={@request.facts["artifact"]}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-block text-sm underline underline-offset-4"
      >
        Open review
      </a>
      <section
        :for={{{width, theme}, images} <- @groups}
        data-width={width}
        data-theme={theme}
        class="space-y-3"
      >
        <h3 class="text-sm font-medium">
          {width || "Original size"}{if width, do: " px"} · {theme || "Theme not set"}
        </h3>
        <div class="grid gap-4 sm:grid-cols-2">
          <figure
            :for={{image, index} <- images}
            id={@prefix <> "review-image-#{@request.id}-#{index}"}
            class="min-w-0 space-y-2 rounded-lg border border-base p-3"
          >
            <a
              href={"/request-images/#{@request.id}/#{index}"}
              target="_blank"
              rel="noopener noreferrer"
              class="block overflow-hidden rounded border border-base transition hover:opacity-90"
            >
              <img
                src={"/request-images/#{@request.id}/#{index}"}
                alt={Path.basename(image["path"])}
                loading="lazy"
                class="h-52 w-full bg-sunken object-contain object-top"
              />
            </a>
            <figcaption class="space-y-1 break-words text-sm">
              <p class="font-medium">{Path.basename(image["path"])}</p>
              <p :if={image["look_at"] || @request.facts["look_at"]} class="text-foreground-softer">
                {image["look_at"] || @request.facts["look_at"]}
              </p>
            </figcaption>
            <.input
              id={@prefix <> "review-comment-#{@request.id}-#{index}"}
              name={"decision[image_comments][#{index}]"}
              value=""
              type="textarea"
              rows="2"
              label="Comment"
              maxlength="2000"
              class="block w-full rounded-lg border border-base bg-sunken px-3 py-2 text-sm text-foreground focus:border-primary"
            />
          </figure>
        </div>
      </section>
    </div>
    """
  end
end
