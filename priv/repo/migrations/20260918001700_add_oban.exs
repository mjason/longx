defmodule Longx.Repo.Migrations.AddOban do
  @moduledoc "Oban's job table (the Lite engine on SQLite): the credential refresh jobs."
  use Ecto.Migration

  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down()
end
