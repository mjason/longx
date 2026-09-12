defmodule Longx.Repo.Migrations.BackfillModelSlug do
  @moduledoc """
  Models created before `slug` existed have none, so codex cannot name them
  (`turn/start.model`) and `Longx.AI.resolve_target/1` cannot find them.
  Same rule as Longx.AI.Model.Changes.DeriveSlug: the upstream id.
  """

  use Ecto.Migration

  def up do
    execute "UPDATE ai_models SET slug = upstream_id WHERE slug IS NULL OR slug = ''"
  end

  def down, do: :ok
end
