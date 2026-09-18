defmodule Longx.Agent.PresentSurfacesTest do
  @moduledoc """
  The surfaces `Plugs.Present` opens for the person besides cards:
  `show_file` / `show_diff` (a workbench tab), `send_file` (a download),
  `show_html` (an artifact). Every path stays inside the project root —
  or the project's attachment directory for a download — and the item
  carries what the client needs under `details`.
  """
  use Longx.DataCase, async: false

  alias Longx.Agent.{Context, Tool}
  alias Longx.Agent.Kernel.UI
  alias Longx.Agent.Plugs.Present
  alias Longx.Projects

  setup do
    Ash.bulk_destroy!(Projects.Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    root = Path.join(System.tmp_dir!(), "longx-surf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "lib/a.ex"), "defmodule A do\nend\n")
    File.write!(Path.join(root, ".git/config"), "[core]\n")
    File.write!(Path.join(root, "out.csv"), "a,b\n1,2\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, project} = Projects.create_project(%{name: "Surf", root_path: root})

    attachments = Path.join(root, "_att")
    previous = Application.get_env(:longx, Projects.Attachments, [])
    Application.put_env(:longx, Projects.Attachments, Keyword.put(previous, :dir, attachments))
    on_exit(fn -> Application.put_env(:longx, Projects.Attachments, previous) end)
    {:ok, stored} = Projects.Attachments.store(project.id, Path.join(root, "out.csv"), "数据.csv")

    # a child agent works in a subdirectory: paths are still project-relative
    %{
      root: root,
      project: project,
      attachment: stored,
      ctx: %Context{cwd: Path.join(root, "lib"), project_id: project.id}
    }
  end

  defp tool!(name), do: Enum.find(Present.__agent_tools__(), &(&1.name == name)) || flunk(name)

  describe "show_file" do
    test "a file inside the root opens: the details carry the project-relative path and the line",
         %{ctx: ctx, root: root} do
      assert {:ok, "opened lib/a.ex for the person", %{"details" => details}} =
               Tool.call(tool!("show_file"), %{"path" => "a.ex", "line" => 2}, ctx)

      assert details == %{"path" => "lib/a.ex", "line" => 2}

      # an absolute path inside the root is the same file
      assert {:ok, _, %{"details" => %{"path" => "lib/a.ex"}}} =
               Tool.call(tool!("show_file"), %{"path" => Path.join(root, "lib/a.ex")}, ctx)
    end

    test "outside the root, inside .git, a directory or a missing file are errors", %{ctx: ctx} do
      assert {:error, msg} = Tool.call(tool!("show_file"), %{"path" => "../../etc/passwd"}, ctx)
      assert msg =~ "outside the project"
      assert {:error, msg} = Tool.call(tool!("show_file"), %{"path" => "../.git/config"}, ctx)
      assert msg =~ "outside the project"
      assert {:error, msg} = Tool.call(tool!("show_file"), %{"path" => "nope.ex"}, ctx)
      assert msg =~ "no such file"
      assert {:error, msg} = Tool.call(tool!("show_file"), %{"path" => "."}, ctx)
      assert msg =~ "not a file"
    end
  end

  describe "show_diff" do
    test "the path is project-relative; a sha is checked for its shape", %{ctx: ctx} do
      assert {:ok, "opened the diff of lib/a.ex for the person",
              %{"details" => %{"path" => "lib/a.ex", "sha" => nil}}} =
               Tool.call(tool!("show_diff"), %{"path" => "a.ex"}, ctx)

      assert {:ok, _, %{"details" => %{"sha" => "abc1234"}}} =
               Tool.call(tool!("show_diff"), %{"path" => "a.ex", "sha" => "abc1234"}, ctx)

      assert {:error, msg} =
               Tool.call(tool!("show_diff"), %{"path" => "a.ex", "sha" => "HEAD"}, ctx)

      assert msg =~ "sha"
      assert {:error, _} = Tool.call(tool!("show_diff"), %{"path" => "../../x"}, ctx)
    end
  end

  describe "send_file" do
    test "a file in the root: name, size, mime and the relative path", %{ctx: ctx} do
      assert {:ok, "sent out.csv to the person (8 B)", %{"details" => details}} =
               Tool.call(tool!("send_file"), %{"path" => "../out.csv"}, ctx)

      assert details == %{
               "path" => "out.csv",
               "name" => "out.csv",
               "bytes" => 8,
               "mime" => "text/csv",
               "attachment" => false,
               "title" => nil
             }

      assert {:ok, _, %{"details" => %{"title" => "结果"}}} =
               Tool.call(tool!("send_file"), %{"path" => "../out.csv", "title" => "结果"}, ctx)
    end

    test "a file of the project's attachment directory is served from there", %{
      ctx: ctx,
      attachment: stored
    } do
      assert {:ok, _, %{"details" => details}} =
               Tool.call(tool!("send_file"), %{"path" => stored.path}, ctx)

      assert %{"attachment" => true, "path" => name, "name" => "数据.csv", "bytes" => 8} = details
      assert name == Path.basename(stored.path)
    end

    test "anything else is refused", %{ctx: ctx} do
      assert {:error, msg} = Tool.call(tool!("send_file"), %{"path" => "/etc/hostname"}, ctx)
      assert msg =~ "outside the project"
      assert {:error, msg} = Tool.call(tool!("send_file"), %{"path" => "missing.bin"}, ctx)
      assert msg =~ "no such file"
    end
  end

  describe "show_html" do
    test "html or an http(s) url, with a title; the details say which", %{ctx: ctx} do
      assert {:ok, "opened 报表 for the person", %{"details" => details}} =
               Tool.call(
                 tool!("show_html"),
                 %{"title" => "报表", "html" => "<h1>hi</h1>"},
                 ctx
               )

      assert details == %{"kind" => "html", "title" => "报表", "bytes" => 11}

      assert {:ok, _, %{"details" => %{"kind" => "url", "url" => "https://example.com/x"}}} =
               Tool.call(
                 tool!("show_html"),
                 %{"title" => "x", "url" => "https://example.com/x"},
                 ctx
               )
    end

    test "neither, both empty, a non-http url or html past 512 KB are errors", %{ctx: ctx} do
      assert {:error, msg} = Tool.call(tool!("show_html"), %{"title" => "x"}, ctx)
      assert msg =~ "html or url"

      assert {:error, msg} =
               Tool.call(tool!("show_html"), %{"title" => "x", "url" => "javascript:1"}, ctx)

      assert msg =~ "http"
      big = String.duplicate("a", 512 * 1024 + 1)
      assert {:error, msg} = Tool.call(tool!("show_html"), %{"title" => "x", "html" => big}, ctx)
      assert msg =~ "512 KB"
    end
  end

  test "the item of a plain tool carries the result's details for the client" do
    tool = Tool.declare(__MODULE__, :show_file, "opens", [], namespace: "longx")

    item =
      UI.completed_ui(tool, "i1", "t1", true, "opened", "", 3, %{"details" => %{"path" => "a"}})

    assert item["details"] == %{"path" => "a"}
    refute Map.has_key?(UI.completed_ui(tool, "i1", "t1", true, "opened", "", 3, %{}), "details")
  end

  test "the four surfaces are declared in the longx namespace next to present" do
    names = Present.__agent_tools__() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ~w(present prompt_user send_file show_diff show_file show_html)
    assert Enum.all?(Present.__agent_tools__(), &(&1.namespace == "longx"))
  end
end
