defmodule Longx.Repo.Migrations.RemoveMemory do
  @moduledoc "The memory module is gone: its two columns go with it (SQLite ≥ 3.35 drops columns)."

  use Ecto.Migration

  def up do
    alter table(:projects) do
      remove :global_memory
    end

    alter table(:project_threads) do
      remove :memory_extracted_at
    end
  end

  def down do
    alter table(:project_threads) do
      add :memory_extracted_at, :utc_datetime_usec
    end

    alter table(:projects) do
      add :global_memory, :boolean, null: false, default: true
    end
  end
end
