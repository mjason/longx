defmodule Longx.Projects.Project.Changes.DeriveSlug do
  @moduledoc "Slug from the name unless one was given: lowercase, dashes, nothing else."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      slug when is_binary(slug) and slug != "" ->
        changeset

      _ ->
        name = Ash.Changeset.get_attribute(changeset, :name) || ""
        Ash.Changeset.force_change_attribute(changeset, :slug, slugify(name))
    end
  end

  @doc false
  def slugify(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\p{Han}]+/u, "-")
      |> String.trim("-")

    if slug == "", do: "project-#{System.unique_integer([:positive])}", else: slug
  end
end
