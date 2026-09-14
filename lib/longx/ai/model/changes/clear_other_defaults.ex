defmodule Longx.AI.Model.Changes.ClearOtherDefaults do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Longx.AI.Model
      |> Ash.Query.filter(default == true and id != ^changeset.data.id)
      |> Ash.bulk_update!(:clear_default, %{}, return_errors?: true, authorize?: false)

      changeset
    end)
  end
end
