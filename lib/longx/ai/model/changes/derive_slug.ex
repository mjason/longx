defmodule Longx.AI.Model.Changes.DeriveSlug do
  @moduledoc "The codex-facing model name: given, or the upstream id."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      slug when is_binary(slug) and slug != "" ->
        changeset

      _ ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :slug,
          Ash.Changeset.get_attribute(changeset, :upstream_id)
        )
    end
  end
end
