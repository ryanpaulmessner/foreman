defmodule ForemanWeb.DocumentsLive do
  use ForemanWeb, :live_view
  alias Foreman.{Documents, Markdown}

  @impl true
  def mount(_, _, socket) do
    {:ok, assign(socket, viewer: Documents.Viewer.__fsm__(:initial))}
  end

  @impl true
  def handle_params(params, _, socket) do
    repos = Foreman.RuntimeState.repos()
    repo = Enum.find(repos, &(&1["key"] == params["repo"]))
    files = if repo, do: Documents.list(repo["path"]), else: []

    path =
      Map.get(params, "path", if("README.md" in files, do: "README.md", else: List.first(files)))

    result = if repo, do: Documents.open(repo, path), else: {:error, :refused}

    {event, document, html} =
      case result do
        {:ok, doc} ->
          {:loaded, doc.path, Markdown.render(doc.content, repo: repo["key"], path: doc.path)}

        _ when is_nil(path) and not is_nil(repo) ->
          {:empty, nil, nil}

        _ ->
          {:missing, nil, nil}
      end

    {viewer, []} = Documents.Viewer.step(socket.assigns.viewer, event, %{})

    {:noreply,
     socket
     |> assign(
       repos: repos,
       repo_key: params["repo"],
       document: document,
       html: html,
       viewer: viewer
     )
     |> stream(:files, Enum.map(files, &%{id: Base.url_encode64(&1, padding: false), path: &1}),
       reset: true
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      drawer_state={@drawer_state}
      drawer_error={@drawer_error}
      streams={@streams}
      flash={@flash}
      active={:documents}
      repos={@repos}
      pending_count={@pending_count}
    >
      <header class="flex flex-wrap items-center gap-3">
        <h1 class="text-xl font-semibold">Documents</h1>
        <span class="text-foreground-softer">{@repo_key}</span>
      </header>
      <div class="grid min-w-0 gap-6 lg:grid-cols-[250px_minmax(0,1fr)]">
        <nav
          aria-label="Documents"
          id="document-files"
          phx-update="stream"
          class="max-h-64 space-y-1 overflow-auto rounded-lg border border-base p-2 lg:sticky lg:top-6 lg:max-h-[80vh] lg:self-start"
        >
          <.link
            :for={{id, file} <- @streams.files}
            id={id}
            patch={Markdown.viewer_path(@repo_key, file.path)}
            aria-current={file.path == @document && "page"}
            title={file.path}
            class={[
              "block rounded px-3 py-2 font-mono text-xs break-words hover:bg-sunken",
              file.path == @document && "bg-sunken font-semibold"
            ]}
          >
            {file.path}
          </.link>
        </nav>
        <article
          :if={@viewer == :ready}
          class="min-w-0 rounded-xl border border-base bg-base p-5 sm:p-8"
        >
          <div class="mb-6 break-all font-mono text-xs text-foreground-softer">{@document}</div>
          <div id="document-content" class="fm-markdown">{Phoenix.HTML.raw(@html)}</div>
        </article>
        <p :if={@viewer != :ready} id="document-status" class="py-6 text-foreground-softer">
          {if @viewer == :empty, do: "No documents", else: "Document unavailable"}
        </p>
      </div>
    </Layouts.app>
    """
  end
end
