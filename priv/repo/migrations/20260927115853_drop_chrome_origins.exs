defmodule Longx.Repo.Migrations.DropChromeOrigins do
  @moduledoc """
  The site rules of a paired browser are gone: opening a site in the person's
  own Chrome no longer asks them, so nothing reads the column.
  """

  use Ecto.Migration

  def up do
    alter table(:chrome_browsers) do
      remove :origins
    end
  end

  def down do
    alter table(:chrome_browsers) do
      add :origins, :map, null: false, default: %{}
    end
  end
end
