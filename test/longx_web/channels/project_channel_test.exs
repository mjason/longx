defmodule LongxWeb.ProjectChannelTest do
  # Per-project signals the browser needs beyond the thread stream: rows
  # changed (refetch), the project's codex going down / coming back, and
  # the recycler's resource samples.
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

  test "the project's codex status is relayed", %{project: project} do
    PubSub.broadcast(Longx.PubSub, "codex:connection", {:codex_connection, project.id, :down})
    assert_push "codex", %{status: "down"}
    PubSub.broadcast(Longx.PubSub, "codex:connection", {:codex_connection, project.id, :ready})
    assert_push "codex", %{status: "ready"}
    # other projects' codex is not our business
    PubSub.broadcast(
      Longx.PubSub,
      "codex:connection",
      {:codex_connection, Ash.UUID.generate(), :down}
    )

    refute_push "codex", %{status: "down"}
  end

  test "recycler samples are relayed", %{project: project} do
    PubSub.broadcast(
      Longx.PubSub,
      "project:" <> project.id,
      {:codex_sample, project.id, %{rss_bytes: 42, processes: 1}}
    )

    assert_push "sample", %{rss_bytes: 42, processes: 1}
  end

  test "files changed under the project (codex's fs/changed) and codex's notices are relayed", %{
    project: project
  } do
    PubSub.broadcast(
      Longx.PubSub,
      "project:" <> project.id,
      {:files_changed, project.id, ["/p/a.txt"]}
    )

    assert_push "files", %{paths: ["/p/a.txt"]}

    PubSub.broadcast(
      Longx.PubSub,
      "project:" <> project.id,
      {:codex_notice, project.id, %{kind: "configWarning", summary: "bad key", details: nil}}
    )

    assert_push "notice", %{kind: "configWarning", summary: "bad key"}
  end

  test "joining an unknown project is refused" do
    assert {:error, %{reason: "unknown project"}} = join!(Ash.UUID.generate())
  end
end
