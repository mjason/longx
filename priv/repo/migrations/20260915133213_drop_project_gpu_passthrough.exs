defmodule Longx.Repo.Migrations.DropProjectGpuPassthrough do
  @moduledoc """
  The GPU is no longer a per-project switch: a machine's GPU device nodes are
  part of every sandbox the exec-server builds (Longx.Projects.passthrough_paths/1).
  """

  use Ecto.Migration

  def up do
    alter table(:projects) do
      remove :gpu_passthrough
    end
  end

  def down do
    alter table(:projects) do
      add :gpu_passthrough, :boolean, null: false, default: false
    end
  end
end
