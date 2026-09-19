defmodule Longx.Repo.Migrations.DropTurnGitBookmarks do
  @moduledoc """
  The per-turn git bookmarks and the project's dirty-tree policy go: Longx
  never commits on the person's behalf any more (the "before turn" commits
  polluted every history they touched) and the restore points went with
  them. SQLite drops a column in place on a single connection
  (`Longx.Migrator`).
  """

  use Ecto.Migration

  def up do
    alter table(:projects) do
      remove :dirty_start
    end

    alter table(:project_turns) do
      remove :diff
      remove :dirty_start
      remove :commit_after
      remove :commit_before
    end
  end

  def down do
    alter table(:project_turns) do
      add :commit_before, :text
      add :commit_after, :text
      add :dirty_start, :boolean, null: false, default: false
      add :diff, :text
    end

    alter table(:projects) do
      add :dirty_start, :text, null: false, default: "commit"
    end
  end
end
