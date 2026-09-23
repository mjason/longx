defmodule LongxWeb.ProjectChannelTest do
  # Per-project signals the browser needs beyond the thread stream: rows
  # changed (refetch) and files changed under the root.
  use LongxWeb.ChannelCase, async: false

  alias Longx.Projects
  alias Phoenix.PubSub

  defp join!(project_id) do
    LongxWeb.UserSocket
    |> socket("user", %{})
    |> subscribe_and_join(LongxWeb.ProjectChannel, "project:" <> project_id)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-pc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    project =
      Projects.create_project!(%{
        name: "PC #{System.unique_integer([:positive])}",
        root_path: dir
      })

    {:ok, _, socket} = join!(project.id)
    %{project: project, socket: socket}
  end

  test "row changes are announced so the client refetches", %{project: project} do
    Projects.broadcast_changed(project.id)
    assert_push "changed", %{}
  end

  test "files changed under the project are relayed", %{project: project} do
    PubSub.broadcast(
      Longx.PubSub,
      "project:" <> project.id,
      {:files_changed, project.id, ["/p/a.txt"]}
    )

    assert_push "files", %{paths: ["/p/a.txt"]}
  end

  test "a changed agent description is announced so the page rereads it (a new chat once ran with the description the page loaded)",
       %{project: project} do
    File.mkdir_p!(Path.join(project.root_path, ".longx/local"))

    File.write!(
      Path.join(project.root_path, ".longx/local/agent.exs"),
      "import Longx.Agent.Config\nagent do\n  model \"x\"\nend\n"
    )

    assert_push "definition", %{}, 3_000

    # nothing changed since: no second push
    refute_push "definition", %{}, 300
  end

  describe "the file watcher" do
    alias Longx.Projects.Watcher

    test "runs while the page is open: files, git and the description are pushed, and it leaves with the page",
         %{project: project, socket: socket} do
      assert_push "watch", %{watching: true, error: nil}, 3_000
      watcher = Watcher.whereis(project.id)
      assert is_pid(watcher)

      File.write!(Path.join(project.root_path, "a.txt"), "a")
      assert_push "files", %{paths: ["a.txt"]}, 3_000

      Longx.Git.init(project.root_path)
      assert_push "files", %{paths: []}, 3_000
      File.write!(Path.join(project.root_path, ".git/HEAD"), "ref: refs/heads/other\n")
      assert_push "git", %{}, 3_000

      ref = Process.monitor(watcher)
      Process.unlink(socket.channel_pid)
      close(socket)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 3_000
      assert Watcher.whereis(project.id) == nil
    end

    test "a watcher that dies is started again for the page", %{project: project} do
      assert_push "watch", %{watching: true}, 3_000
      Process.exit(Watcher.whereis(project.id), :kill)
      assert_push "watch", %{watching: true}, 5_000
      assert is_pid(Watcher.whereis(project.id))
    end

    test "while the watcher is down the description is polled (a stopped shim)",
         %{project: project} do
      assert_push "watch", %{watching: true}, 3_000
      System.cmd("kill", ["-9", "#{Watcher.os_pid(project.id)}"])
      assert_push "watch", %{watching: false, error: error}, 3_000
      assert error =~ "stopped"

      File.mkdir_p!(Path.join(project.root_path, ".longx/local"))
      File.write!(Path.join(project.root_path, ".longx/local/agent.exs"), "agent do end\n")
      assert_push "definition", %{}, 3_000
    end
  end

  test "joining an unknown project is refused" do
    assert {:error, %{reason: "unknown project"}} = join!(Ash.UUID.generate())
  end
end
