defmodule Longx.System.CommandsTest do
  use Longx.DataCase, async: false

  alias Longx.System.{Commands, Pressure}

  test "the live commands are listed with their session and killed by id: the tool process is told and reports the person" do
    me = self()

    runner =
      spawn_link(fn ->
        :ok =
          Pressure.register(%{
            shim: nil,
            floor: 0,
            cmd: "uv run jbt run x",
            thread_id: "native_nobody",
            id: "cmd_1",
            started_at: System.system_time(:millisecond) - 5_000
          })

        send(me, :registered)

        receive do
          {:kill_command, by} -> send(me, {:killed, by})
        end
      end)

    assert_receive :registered

    assert [
             %{
               id: "cmd_1",
               cmd: "uv run jbt run x",
               thread_id: "native_nobody",
               session: nil,
               elapsed_ms: ms
             }
           ] =
             Enum.filter(Commands.list(), &(&1.id == "cmd_1"))

    assert ms >= 5_000
    ref = Process.monitor(runner)
    assert :ok = Commands.kill("cmd_1")
    assert_receive {:killed, :person}
    # the entry goes with the tool's process (the registry notices its exit)
    assert_receive {:DOWN, ^ref, :process, ^runner, _}
    eventually(fn -> not Enum.any?(Commands.list(), &(&1.id == "cmd_1")) end)
    assert {:error, :not_found} = Commands.kill("cmd_1")
  end

  defp eventually(fun, tries \\ 50) do
    if fun.() do
      :ok
    else
      if tries == 0, do: flunk("never true")
      Process.sleep(20)
      eventually(fun, tries - 1)
    end
  end

  test "a command of a project thread is listed with the session's title and the project's slug",
       %{} do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "longx-cmds-#{n}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    project = Longx.Projects.create_project!(%{name: "Cmds #{n}", root_path: dir})
    {:ok, thread} = Longx.Projects.start_thread(project)
    Longx.Projects.rename_thread!(thread, %{title: "值班"})
    me = self()

    spawn_link(fn ->
      :ok =
        Pressure.register(%{
          shim: nil,
          floor: 0,
          cmd: "sleep 100",
          thread_id: thread.kernel_thread_id,
          id: "cmd_2",
          started_at: System.system_time(:millisecond)
        })

      send(me, :registered)
      receive do: (_ -> :ok)
    end)

    assert_receive :registered

    assert [%{session: %{title: "值班", slug: slug, thread_row_id: row}}] =
             Enum.filter(Commands.list(), &(&1.id == "cmd_2"))

    assert slug == project.slug and row == thread.id
    Longx.Test.Agents.stop_all!()
  end
end
