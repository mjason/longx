defmodule Longx.Projects.ResilienceTest do
  @moduledoc """
  What happens to project threads and turns when their codex dies, comes
  back, or stops making progress. Uses the per-project pool with the fake
  app-server (no `conn:` passed: the pool is the default).
  """
  use Longx.DataCase, async: false

  alias Longx.Codex.Pool
  alias Longx.Projects
  alias Longx.Projects.{Thread, Turn}

  setup do
    Ash.bulk_destroy!(Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)

    dir = Path.join(System.tmp_dir!(), "longx-res-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    project =
      Projects.create_project!(%{name: "R #{System.unique_integer([:positive])}", root_path: dir})

    Phoenix.PubSub.subscribe(Longx.PubSub, "codex:connection")

    on_exit(fn ->
      Longx.Test.PoolHelpers.stop_pool!([project.id])
      File.rm_rf!(dir)
    end)

    %{project: project}
  end

  defp eventually(fun, attempts \\ 100) do
    case fun.() do
      {:ok, value} ->
        value

      _ when attempts > 0 ->
        Process.sleep(50)
        eventually(fun, attempts - 1)

      other ->
        flunk("condition not met: #{inspect(other)}")
    end
  end

  defp turn_status(turn_id, wanted) do
    fn ->
      case Ash.get!(Turn, turn_id) do
        %{status: ^wanted} = turn -> {:ok, turn}
        other -> {:pending, other.status}
      end
    end
  end

  defp thread_status(thread_id, wanted) do
    fn ->
      case Ash.get!(Thread, thread_id) do
        %{status: ^wanted} = thread -> {:ok, thread}
        other -> {:pending, other.status}
      end
    end
  end

  test "without conn: the project's pooled codex is used", %{project: project} do
    {:ok, thread} = Projects.start_thread(project)
    project_id = project.id
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    {:ok, turn} = Projects.send_message(thread, "say hi")
    assert %{status: :completed} = eventually(turn_status(turn.id, :completed))
    assert project_id in Pool.running()
  end

  test "codex dies mid-turn: the turn fails, the thread is disconnected, then resumed when codex is back",
       %{project: project} do
    project_id = project.id
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000

    # a turn is running when the fake is told to exit
    {:ok, running} = Projects.send_message(thread, "stall")
    _ = Projects.send_message(thread, "die")
    assert_receive {:codex_connection, ^project_id, :down}, 5_000

    failed = eventually(turn_status(running.id, :failed))
    assert failed.error =~ "codex"
    assert %DateTime{} = failed.completed_at

    # the worker restarts on its own; the thread is resumed there
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    idle = eventually(thread_status(thread.id, :idle))
    assert idle.status == :idle

    # and it keeps working on the new process
    {:ok, turn} = Projects.send_message(thread, "say again")
    assert %{status: :completed} = eventually(turn_status(turn.id, :completed))
  end

  test "a thread that cannot be resumed is marked unrecoverable and refuses new messages",
       %{project: project} do
    project_id = project.id
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    # the fake forgets threads when it dies; a thread it never saw cannot be resumed
    Projects.touch_thread!(thread, %{status: :active})

    Ash.update!(
      Ash.Changeset.for_update(thread, :touch, %{})
      |> Ash.Changeset.force_change_attribute(:codex_thread_id, "thr_never_existed")
    )

    :ok = Projects.stop_codex(project, force: true)
    assert_receive {:codex_connection, ^project_id, :down}, 5_000
    assert %{status: :disconnected} = Ash.get!(Thread, thread.id)

    {:ok, _} = Pool.connection(project_id)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000
    unrecoverable = eventually(thread_status(thread.id, :unrecoverable))
    assert {:error, :thread_unrecoverable} = Projects.send_message(unrecoverable, "say x")
  end

  test "a turn with no progress is interrupted (stall timeout)", %{project: project} do
    old = Application.get_env(:longx, Longx.Projects.Tracker, [])
    Application.put_env(:longx, Longx.Projects.Tracker, stall_after: 300, tick: 100)
    on_exit(fn -> Application.put_env(:longx, Longx.Projects.Tracker, old) end)

    project_id = project.id
    {:ok, thread} = Projects.start_thread(project)
    assert_receive {:codex_connection, ^project_id, :ready}, 15_000

    {:ok, turn} = Projects.send_message(thread, "stall")
    done = eventually(turn_status(turn.id, :interrupted))
    assert done.error =~ "no progress"
    assert %{status: :idle} = Ash.get!(Thread, thread.id)
  end
end
