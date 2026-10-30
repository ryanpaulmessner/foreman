defmodule Foreman.StageGuidance do
  @moduledoc "The next CLI step when a stage guard refuses a command."
  def next(stage, id, actor \\ nil)

  def next(stage, id, "claude") when stage in [:queued, :dispatched, :building],
    do: "foreman commit #{id} --sha <sha>"

  def next(stage, id, _actor) do
    case stage do
      :queued ->
        "foreman dispatch #{id} --session <build-name> --window <window>"

      stage when stage in [:dispatched, :building] ->
        "foreman report #{id} --path <report>"

      :reported ->
        "foreman review #{id}"

      :in_review ->
        "foreman commit #{id} --sha <sha>"

      :committed ->
        "foreman ask push #{id} --worktree <path> --branch <branch> --sha <sha> --remote-branch <branch>"

      :abandoned ->
        "foreman revive #{id}"

      :done ->
        "foreman reopen #{id}"

      :idea ->
        "foreman epic spec #{id}"

      :speccing ->
        "foreman epic approve #{id} --spec <path>"

      :spec_approved ->
        "foreman epic ticket #{id} --beads-epic-id <epic>"

      _ ->
        "foreman show #{id} --overlay --json"
    end
  end
end
