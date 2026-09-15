defmodule Longx.Repo.Migrations.WritableRootsDefaultEmpty do
  @moduledoc """
  0.1.7 gave every project `writable_roots = ["~/.cache"]` (the column
  default filled existing rows too), widening every workspace-write sandbox
  without anyone choosing it. The resource default is `[]` again; rows still
  on that unasked-for value go back to empty. Rows someone edited are kept.
  The column's own SQLite default stays (a rebuild for nothing: Ash always
  writes the attribute).
  """
  use Ecto.Migration

  def up do
    execute ~s|UPDATE projects SET writable_roots = '[]' WHERE writable_roots = '["~/.cache"]'|
  end

  def down, do: :ok
end
