defmodule Foreman.Epic do
  @moduledoc "Spec Decision 8. :new_draft models the table's pre-create origin."
  use Foreman.Fsm, observed_never_invalid: true

  initial(:new_draft)
  state(:new_draft)
  state(:idea)
  state(:speccing)
  state(:spec_approved)
  state(:ticketed)
  state(:abandoned)
  state(:done)
  group(:draft, [:idea, :speccing, :spec_approved])

  event(:create, source: :claimed)
  event(:start_spec, source: :claimed)
  event(:approve_spec, source: :claimed)
  event(:ticket, source: :claimed)
  event(:abandon, source: :claimed)
  event(:revive, source: :claimed)
  event(:bead_epic_closed, source: :observed)
  event(:bead_epic_reopened, source: :observed)
  effects([:record, :link])
  guard(:beads_epic_id?)

  transition(:create, from: :new_draft, to: :idea, do: [record: :draft])
  transition(:start_spec, from: :idea, to: :speccing)

  transition(:approve_spec,
    from: :speccing,
    to: :spec_approved,
    do: [record: :spec_link, record: :design_link]
  )

  transition(:ticket,
    from: :spec_approved,
    to: :ticketed,
    guard: :beads_epic_id?,
    do: [link: :beads_epic]
  )

  transition(:abandon, from: :draft, to: :abandoned)
  transition(:revive, from: :abandoned, to: :idea)
  transition(:bead_epic_closed, from: :any, to: :done)
  transition(:bead_epic_reopened, from: :done, to: :ticketed)
  ignore([:bead_epic_closed, :bead_epic_reopened], from: :any)
  invalid([:create, :start_spec, :approve_spec, :ticket, :abandon, :revive], from: :any)

  def beads_epic_id?(_, %{beads_epic_id: id}) when is_binary(id), do: byte_size(id) > 0
  def beads_epic_id?(_, _), do: false
end
