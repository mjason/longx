defmodule Longx.AI.Model.Changes.DeriveSlug do
  @moduledoc "Keep explicit names; allocate an unused name for an implicit upstream id."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      slug when is_binary(slug) and slug != "" ->
        changeset

      _ ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :slug,
          Ash.Changeset.get_attribute(changeset, :upstream_id)
        )
        # SQLite's IMMEDIATE write transaction serializes allocation with the
        # insert. Choosing before the transaction would race other providers.
        |> Ash.Changeset.before_action(&allocate/1)
    end
  end

  defp allocate(changeset) do
    provider_id = Ash.Changeset.get_attribute(changeset, :provider_id)
    base = Ash.Changeset.get_attribute(changeset, :slug)

    with {:ok, provider} <- Ash.get(Longx.AI.Provider, provider_id),
         {:ok, models} <- Longx.AI.list_models(load: []) do
      taken = MapSet.new(models, & &1.slug)
      prefix = "#{provider.slug}-#{base}"

      slug =
        Stream.concat(
          [base, prefix],
          Stream.iterate(2, &(&1 + 1)) |> Stream.map(&"#{prefix}-#{&1}")
        )
        |> Enum.find(&(not MapSet.member?(taken, &1) and &1 != "longx"))

      Ash.Changeset.force_change_attribute(changeset, :slug, slug)
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end
end
