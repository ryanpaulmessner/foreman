defmodule Foreman.CardList do
  @moduledoc """
  The card list on Needs you (question cards spec, Decision 39): which pending
  card is open, and the lines that say what happened to a card. One per page.

  - `loading`: the list has not loaded yet.
  - `empty`: no card is pending.
  - `closed`: cards are pending and every one is a row.
  - `open`: one card is open.
  - `failed`: one card is open and its last action failed.

  The machine decides the state and the effects; the functions below apply them
  to the list data and return `{list, host_effects}`. Host effects are what the
  page must do outside the list: `card_closed: id` (fire `Foreman.CardAsk`
  `card_closed`, the input is kept), `drop_input: id` and `expire: id` (start
  the 10 s timer of a result line). An event the state does not accept leaves
  the list as it is.

  Rules: at most one card is open (R1). A poll or a new card never closes,
  moves or resets the open card (R2). Closing a card or opening another one
  keeps your input (R3). After you act, a result line takes the card's place
  and the row under it opens, else the first row (R4, Decision 5). A card never
  leaves without a line that says why (R6).
  """
  use Foreman.Fsm
  alias Foreman.QueuedNotes

  defstruct state: :loading,
            order: [],
            open: nil,
            lines: %{},
            notice: nil,
            load_error: false,
            error: nil

  @type line :: {:result, term()} | {:closed, term()}
  @type t :: %__MODULE__{
          state: :loading | :empty | :closed | :open | :failed,
          order: [String.t()],
          open: String.t() | nil,
          lines: %{String.t() => line},
          notice: :stale | nil,
          load_error: boolean(),
          error: term()
        }

  initial(:loading)
  state(:loading)
  state(:empty, enter: [close_card: :open])
  state(:closed, enter: [close_card: :open])
  state(:open)
  state(:failed, exit: [clear_error: :card])
  group(:fresh, [:loading, :empty])
  group(:showing, [:open, :failed])

  event(:loaded, source: :observed)
  event(:load_failed, source: :observed)
  event(:open_row)
  event(:close)
  event(:resolved)
  event(:resolve_failed)
  event(:line_expired, source: :observed)
  event(:dismiss_line)
  event(:note_changed, source: :observed)

  effects([
    :show_rows,
    :open_card,
    :close_card,
    :keep_input,
    :drop_input,
    :clear_lines,
    :result_line,
    :closed_line,
    :stale_line,
    :error_line,
    :clear_error,
    :remove_line,
    :update_line,
    :load_error
  ])

  guard(:wanted_pending?)
  guard(:stale_with_rows?)
  guard(:stale_want?)
  guard(:any_pending?)
  guard(:open_pending?)
  guard(:already_open?)
  guard(:row_pending?)
  guard(:others_pending?)

  transition(:loaded,
    from: :fresh,
    to: :open,
    guard: :wanted_pending?,
    do: [show_rows: :list, open_card: :wanted]
  )

  transition(:loaded,
    from: :fresh,
    to: :open,
    guard: :stale_with_rows?,
    do: [show_rows: :list, open_card: :first, stale_line: :page]
  )

  transition(:loaded,
    from: :fresh,
    to: :open,
    guard: :any_pending?,
    do: [show_rows: :list, open_card: :first]
  )

  transition(:loaded,
    from: :fresh,
    to: :empty,
    guard: :stale_want?,
    do: [show_rows: :list, stale_line: :page]
  )

  transition(:loaded, from: :fresh, to: :empty, do: [show_rows: :list])
  transition(:loaded, from: :closed, to: :stay, guard: :any_pending?, do: [show_rows: :list])
  transition(:loaded, from: :closed, to: :empty, do: [show_rows: :list])
  transition(:loaded, from: :showing, to: :stay, guard: :open_pending?, do: [show_rows: :list])

  transition(:loaded,
    from: :showing,
    to: :open,
    guard: :any_pending?,
    do: [closed_line: :open_card, open_card: :next, show_rows: :list]
  )

  transition(:loaded,
    from: :showing,
    to: :empty,
    do: [closed_line: :open_card, show_rows: :list]
  )

  transition(:load_failed, from: :any, to: :stay, do: [load_error: :page])

  transition(:open_row, from: :showing, to: :stay, guard: :already_open?)

  transition(:open_row,
    from: [:closed, :open, :failed],
    to: :open,
    guard: :row_pending?,
    do: [keep_input: :open_card, clear_lines: :your_action, open_card: :row]
  )

  transition(:open_row, from: [:closed, :open, :failed], to: :stay, do: [stale_line: :page])
  transition(:open_row, from: :fresh, to: :stay, do: [stale_line: :page])

  transition(:close,
    from: :showing,
    to: :closed,
    do: [keep_input: :open_card, clear_lines: :your_action]
  )

  ignore(:close, from: [:loading, :empty, :closed])

  transition(:resolved,
    from: :showing,
    to: :open,
    guard: :others_pending?,
    do: [
      clear_lines: :your_action,
      result_line: :card,
      drop_input: :card,
      open_card: :next,
      show_rows: :list
    ]
  )

  transition(:resolved,
    from: :showing,
    to: :empty,
    do: [clear_lines: :your_action, result_line: :card, drop_input: :card, show_rows: :list]
  )

  invalid(:resolved, from: [:loading, :empty, :closed])

  transition(:resolve_failed,
    from: :showing,
    to: :failed,
    do: [clear_lines: :your_action, error_line: :card]
  )

  invalid(:resolve_failed, from: [:loading, :empty, :closed])
  transition(:line_expired, from: :any, to: :stay, do: [remove_line: :line])
  transition(:dismiss_line, from: :any, to: :stay, do: [remove_line: :line])
  transition(:note_changed, from: :any, to: :stay, do: [update_line: :note])

  # Guards: `payload.ids` are the pending card ids in list order.
  def wanted_pending?(_, %{want: want, ids: ids}), do: want != nil and want in ids
  def wanted_pending?(_, _), do: false

  def stale_with_rows?(list, payload), do: stale_want?(list, payload) and payload.ids != []

  def stale_want?(_, %{want: want, ids: ids}), do: want != nil and want not in ids
  def stale_want?(_, _), do: false

  def any_pending?(_, %{ids: ids}), do: ids != []
  def open_pending?(list, %{ids: ids}), do: list.open in ids
  def already_open?(list, %{id: id}), do: list.open == id
  def row_pending?(list, %{id: id}), do: id in pending(list)
  def others_pending?(_, %{id: id, ids: ids}), do: Enum.any?(ids, &(&1 != id))

  @doc "A list that has not loaded yet."
  def new, do: %__MODULE__{}

  @doc "The pending card ids in list order (the rows and the open card)."
  def pending(list), do: Enum.reject(list.order, &Map.has_key?(list.lines, &1))

  @doc """
  The pending card ids in list order were read. Options: `want`, the card the
  URL names (first load only); `closed`, a function that gives the line info of
  the open card when it left elsewhere.
  """
  def loaded(list, ids, opts \\ []) do
    fire(list, :loaded, %{
      ids: ids,
      want: opts[:want],
      closed: Keyword.get(opts, :closed, fn _ -> nil end)
    })
  end

  @doc "The list could not be read; the rows stay as they were."
  def load_failed(list), do: fire(list, :load_failed, %{})

  @doc "You opened a row (row click, Enter or Space, the `card` URL parameter)."
  def open_row(list, id), do: fire(list, :open_row, %{id: id})

  @doc "You closed the open card."
  def close(list), do: fire(list, :close, %{})

  @doc "Your action on the open card took it out of pending; `ids` are the cards still pending."
  def resolved(list, id, ids, line), do: fire(list, :resolved, %{id: id, ids: ids, line: line})

  @doc "Your action on the open card failed; `error` is the error line info."
  def resolve_failed(list, id, error), do: fire(list, :resolve_failed, %{id: id, error: error})

  @doc "A result line's 10 s ran out."
  def line_expired(list, id), do: fire(list, :line_expired, %{id: id})

  @doc "You closed a line with its X."
  def dismiss_line(list, id), do: fire(list, :dismiss_line, %{id: id})

  @doc """
  The note of card `id`'s result line, saved for a busy coordinator (fm-9mm.23), was read
  again as `note`. The line follows it; its 10 s start when the note no longer waits.
  """
  def note_changed(list, id, note), do: fire(list, :note_changed, %{id: id, note: note})

  defp fire(list, event, payload) do
    case step(list.state, {event, payload}, list) do
      {:error, _} ->
        {list, []}

      {state, effects} ->
        {list, host} =
          Enum.reduce(effects, {list, []}, fn effect, {list, host} ->
            {list, more} = apply_effect(effect, list, payload)
            {list, host ++ more}
          end)

        {%{list | state: state}, host}
    end
  end

  defp apply_effect({:show_rows, :list}, list, %{ids: ids}),
    do: {%{list | order: merge(list.order, list.lines, ids), load_error: false}, []}

  defp apply_effect({:open_card, :wanted}, list, %{want: id}), do: {%{list | open: id}, []}
  defp apply_effect({:open_card, :first}, list, %{ids: [id | _]}), do: {%{list | open: id}, []}
  defp apply_effect({:open_card, :row}, list, %{id: id}), do: {%{list | open: id}, []}

  defp apply_effect({:open_card, :next}, list, %{ids: ids} = payload),
    do: {%{list | open: next(list.order, payload[:id] || list.open, ids)}, []}

  defp apply_effect({:close_card, :open}, list, _), do: {%{list | open: nil}, []}

  defp apply_effect({:keep_input, :open_card}, list, _),
    do: {list, if(list.open, do: [card_closed: list.open], else: [])}

  defp apply_effect({:drop_input, :card}, list, %{id: id}), do: {list, [drop_input: id]}

  defp apply_effect({:clear_lines, :your_action}, list, _) do
    gone = for {id, {:closed, _}} <- list.lines, do: id

    {%{
       list
       | lines: Map.drop(list.lines, gone),
         order: list.order -- gone,
         notice: nil
     }, []}
  end

  defp apply_effect({:result_line, :card}, list, %{id: id, line: line}),
    do: {%{list | lines: Map.put(list.lines, id, {:result, line})}, expire(id, line)}

  defp apply_effect({:update_line, :note}, list, %{id: id, note: note}) do
    case list.lines[id] do
      {:result, %{note: %{} = old} = line} when old != note ->
        host =
          if QueuedNotes.waiting?(old) and not QueuedNotes.waiting?(note),
            do: [expire: id],
            else: []

        {%{list | lines: Map.put(list.lines, id, {:result, %{line | note: note}})}, host}

      _ ->
        {list, []}
    end
  end

  defp apply_effect({:closed_line, :open_card}, list, %{closed: info}),
    do: {%{list | lines: Map.put(list.lines, list.open, {:closed, info.(list.open)})}, []}

  defp apply_effect({:stale_line, :page}, list, _), do: {%{list | notice: :stale}, []}
  defp apply_effect({:error_line, :card}, list, %{error: error}), do: {%{list | error: error}, []}
  defp apply_effect({:clear_error, :card}, list, _), do: {%{list | error: nil}, []}

  defp apply_effect({:remove_line, :line}, list, %{id: id}) do
    if Map.has_key?(list.lines, id),
      do: {%{list | lines: Map.delete(list.lines, id), order: List.delete(list.order, id)}, []},
      else: {list, []}
  end

  defp apply_effect({:load_error, :page}, list, _), do: {%{list | load_error: true}, []}

  # A result line whose note waits for a busy coordinator stays until the note is sent.
  defp expire(id, %{note: note}),
    do: if(QueuedNotes.waiting?(note), do: [], else: [expire: id])

  defp expire(id, _), do: [expire: id]

  # The row under `id` in the list as it was, still pending; else the first row.
  defp next(order, id, ids) do
    pending = MapSet.new(ids)

    order
    |> Enum.drop_while(&(&1 != id))
    |> Enum.drop(1)
    |> Enum.find(&MapSet.member?(pending, &1)) || List.first(ids)
  end

  # The new pending order, with each line kept after the row it followed.
  defp merge(order, lines, ids) do
    order
    |> Enum.with_index()
    |> Enum.filter(fn {id, _} -> Map.has_key?(lines, id) and id not in ids end)
    |> Enum.reduce(ids, fn {id, index}, acc ->
      before = order |> Enum.take(index) |> Enum.reverse() |> Enum.find(&(&1 in acc))

      case before && Enum.find_index(acc, &(&1 == before)) do
        nil -> [id | acc]
        at -> List.insert_at(acc, at + 1, id)
      end
    end)
  end
end
