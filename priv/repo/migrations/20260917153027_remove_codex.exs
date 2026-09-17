defmodule Longx.Repo.Migrations.RemoveCodex do
  @moduledoc """
  The codex engine is gone: the agent kernel is the only one. Its columns
  go (sandbox, approvals, tools, the exec-server's roots, the process cap,
  the engine switch, the fork link), the two ids are renamed after the
  kernel, the `ai_tools` catalogue is dropped. A thread that ran on codex
  cannot run again — its conversation lived in codex's own store — so such
  rows become `unrecoverable` (they still open, read-only) and a thread
  left `disconnected` by a dead codex is idle.

  Hand-written: the generator comments removals out (SQLite ≥ 3.35 drops
  columns; an indexed column needs its index dropped first).
  """

  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:ai_tools, [:namespace, :name],
                     name: "ai_tools_unique_qualified_name_index"
                   )

    drop_if_exists table(:ai_tools)

    alter table(:projects) do
      remove :approval_policy
      remove :sandbox
      remove :tools
      remove :network_access
      remove :writable_roots
      remove :passthrough_paths
      remove :multi_agent
      remove :auto_review
      remove :engine
      remove :memory_limit_mb
    end

    drop_if_exists unique_index(:project_threads, [:codex_thread_id],
                     name: "project_threads_unique_codex_thread_id_index"
                   )

    rename table(:project_threads), :codex_thread_id, to: :kernel_thread_id

    alter table(:project_threads) do
      remove :approval_policy
      remove :sandbox
      remove :network_access
      remove :multi_agent
      remove :auto_review
      remove :tools
      remove :forked_from_id
    end

    create unique_index(:project_threads, [:kernel_thread_id],
             name: "project_threads_unique_kernel_thread_id_index"
           )

    execute "UPDATE project_threads SET status = 'idle' WHERE status = 'disconnected'"

    execute """
    UPDATE project_threads SET status = 'unrecoverable'
    WHERE kernel_thread_id NOT LIKE 'native\\_%' ESCAPE '\\' AND status <> 'archived'
    """

    drop_if_exists unique_index(:project_turns, [:codex_turn_id],
                     name: "project_turns_unique_codex_turn_id_index"
                   )

    rename table(:project_turns), :codex_turn_id, to: :kernel_turn_id

    create unique_index(:project_turns, [:kernel_turn_id],
             name: "project_turns_unique_kernel_turn_id_index"
           )
  end

  def down do
    drop_if_exists unique_index(:project_turns, [:kernel_turn_id],
                     name: "project_turns_unique_kernel_turn_id_index"
                   )

    rename table(:project_turns), :kernel_turn_id, to: :codex_turn_id

    create unique_index(:project_turns, [:codex_turn_id],
             name: "project_turns_unique_codex_turn_id_index"
           )

    drop_if_exists unique_index(:project_threads, [:kernel_thread_id],
                     name: "project_threads_unique_kernel_thread_id_index"
                   )

    rename table(:project_threads), :kernel_thread_id, to: :codex_thread_id

    alter table(:project_threads) do
      add :approval_policy, :text, null: false, default: "on_request"
      add :sandbox, :text, null: false, default: "workspace_write"
      add :network_access, :boolean, null: false, default: false
      add :multi_agent, :boolean, null: false, default: true
      add :auto_review, :boolean, null: false, default: true
      add :tools, {:array, :text}, null: false, default: []

      add :forked_from_id,
          references(:project_threads,
            column: :id,
            name: "project_threads_forked_from_id_fkey",
            type: :uuid
          )
    end

    create unique_index(:project_threads, [:codex_thread_id],
             name: "project_threads_unique_codex_thread_id_index"
           )

    alter table(:projects) do
      add :approval_policy, :text, null: false, default: "on_request"
      add :sandbox, :text, null: false, default: "workspace_write"
      add :tools, {:array, :text}, null: false, default: []
      add :network_access, :boolean, null: false, default: false
      add :writable_roots, {:array, :text}, null: false, default: []
      add :passthrough_paths, {:array, :text}, null: false, default: []
      add :multi_agent, :boolean, null: false, default: true
      add :auto_review, :boolean, null: false, default: true
      add :engine, :text, null: false, default: "codex"
      add :memory_limit_mb, :bigint
    end

    create table(:ai_tools, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :namespace, :text, null: false
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:ai_tools, [:namespace, :name],
             name: "ai_tools_unique_qualified_name_index"
           )
  end
end
