defmodule Longx.ProjectDeleteLockTest do
  # A real WAL file and separate connections: the sandbox shares one
  # connection, which cannot expose a writer waiting for the deleter's lock.
  use ExUnit.Case, async: false

  alias Longx.Agent.Transcript
  alias Longx.Agent.Transcript.{Item, Writer}
  alias Longx.{Projects, Repo}

  @repo :project_delete_lock_repo

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-delete-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    db = Path.join(dir, "delete.db")
    :ok = Longx.Migrator.migrate(database: db)

    start_supervised!(
      {Repo,
       name: @repo,
       database: db,
       pool: DBConnection.ConnectionPool,
       pool_size: 2,
       busy_timeout: 100,
       timeout: 2_000}
    )

    Repo.put_dynamic_repo(@repo)
    assert :ok = Writer.flush()
    original = :sys.get_state(Writer)

    :sys.replace_state(Writer, fn state ->
      %{
        state
        | waits: [],
          write: fn batch ->
            Repo.put_dynamic_repo(@repo)

            try do
              original.write.(batch)
            after
              Repo.put_dynamic_repo(Repo)
            end
          end
      }
    end)

    on_exit(fn ->
      :sys.resume(Writer)
      Writer.flush()

      :sys.replace_state(Writer, fn state ->
        %{state | write: original.write, waits: original.waits}
      end)

      File.rm_rf!(dir)
    end)

    project = Projects.create_project!(%{name: "Delete lock", root_path: dir})

    thread =
      Projects.create_thread!(%{
        project_id: project.id,
        kernel_thread_id: "native_delete_lock",
        cwd: dir
      })

    %{project: project, thread: thread}
  end

  test "deleting a project flushes transcript writes before it takes SQLite's write lock",
       %{project: project, thread: thread} do
    before = Writer.stats()
    :sys.suspend(Writer)

    try do
      # Another session has an event waiting to be persisted. The deleter
      # must let that write through before beginning its own transaction.
      Transcript.append!(%{
        thread_id: "other-session",
        turn_id: "other-turn",
        seq: 1,
        kind: :user_message,
        input: %{"role" => "user", "content" => "keep this"}
      })

      Transcript.append!(%{
        thread_id: thread.kernel_thread_id,
        turn_id: "deleted-turn",
        seq: 1,
        kind: :user_message,
        input: %{"role" => "user", "content" => "delete this"}
      })

      task =
        Task.async(fn ->
          Repo.put_dynamic_repo(@repo)
          Projects.delete_project(project, confirm: true)
        end)

      assert waiting_for_flush?()
      :sys.resume(Writer)
      assert :ok = Task.await(task, 5_000)

      # Under the old ordering the writer timed out behind the deleter's
      # transaction and dropped the unrelated session's item.
      assert Writer.stats().dropped == before.dropped
      assert [%Item{thread_id: "other-session"}] = Ash.read!(Item)
      assert [] = Projects.list_projects!(include_archived: true)
    after
      :sys.resume(Writer)
    end
  end

  defp waiting_for_flush?(tries \\ 100) do
    {:messages, messages} = Process.info(Process.whereis(Writer), :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _, :flush}, &1)) do
      true
    else
      if tries > 0 do
        receive do
        after
          10 -> waiting_for_flush?(tries - 1)
        end
      else
        false
      end
    end
  end
end
