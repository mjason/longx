defmodule Longx.Projects.Errors.DirtyTree do
  @moduledoc """
  `send_message/3` refused to start a turn because the working tree has
  uncommitted changes and the project's `dirty_start` policy is `:ask`. Over
  RPC it is `type: "dirty_tree"` with the changed files in `details`, so the
  UI can offer "commit first" / "ignore" (`dirty: :commit | :ignore`).
  """
  use Splode.Error, fields: [:changes], class: :invalid

  def message(%{changes: changes}) do
    "the working tree has #{length(changes)} uncommitted change(s); choose to commit or ignore them"
  end
end

defimpl AshTypescript.Rpc.Error, for: Longx.Projects.Errors.DirtyTree do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Uncommitted changes",
      type: "dirty_tree",
      vars: %{},
      fields: [],
      path: [],
      details: %{
        changes:
          Enum.map(error.changes, fn change ->
            %{path: change.path, status: change.status}
          end)
      }
    }
  end
end
