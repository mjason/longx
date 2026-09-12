defmodule Longx.AI.Provider.Changes.ErrorAtFromError do
  @moduledoc false
  # `last_error_at` follows `last_error`: stamped when an error is recorded,
  # cleared with it.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    case Ash.Changeset.get_attribute(changeset, :last_error) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :last_error_at, nil)
      _ -> Ash.Changeset.force_change_attribute(changeset, :last_error_at, DateTime.utc_now())
    end
  end
end
