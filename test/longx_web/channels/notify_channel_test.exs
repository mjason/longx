defmodule LongxWeb.NotifyChannelTest do
  # `notify` — one feed of what the person should hear about across projects:
  # a turn waiting on them, a turn done or failed, a codex that died mid-turn.
  # The Android shell's foreground service joins it and raises notifications.
  use LongxWeb.ChannelCase, async: false

  alias Longx.Notify
  alias Longx.Projects

  defp join! do
    LongxWeb.UserSocket
    |> socket("user", %{})
    |> subscribe_and_join(LongxWeb.NotifyChannel, "notify")
  end

  test "join answers with what runs now; every event pushed is one `event`" do
    dir = Path.join(System.tmp_dir!(), "longx-nc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    project =
      Projects.create_project!(%{
        name: "NC #{System.unique_integer([:positive])}",
        root_path: dir
      })

    thread =
      Projects.create_thread!(%{
        project_id: project.id,
        codex_thread_id: "thr_nc",
        cwd: dir,
        sandbox: :workspace_write,
        approval_policy: :on_request,
        status: :active
      })

    {:ok, reply, _socket} = join!()
    assert %{running: [%{id: id, project_slug: slug, waiting: false}]} = reply
    assert id == thread.id
    assert slug == project.slug

    Notify.push(%{
      kind: "approval",
      title: "等待审批",
      body: "ls",
      url: "/p/#{slug}/t/#{thread.id}",
      project_id: project.id,
      thread_id: thread.id
    })

    assert_push "event", %{kind: "approval", title: "等待审批", body: "ls", url: url, at: at}
    assert url == "/p/#{slug}/t/#{thread.id}"
    assert is_binary(at)
  end
end
