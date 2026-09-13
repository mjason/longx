defmodule LongxWeb.WorkspaceRpcTest do
  @moduledoc """
  The file tree / editor and the git tool over the wire (`POST /rpc/run`):
  `Longx.Projects.Files` and `Longx.Projects.Repo` generic actions.
  """
  use LongxWeb.ConnCase, async: false

  alias Longx.Git
  alias Longx.Projects

  setup do
    Ash.bulk_destroy!(Projects.Turn, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Thread, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Projects.Project, :destroy, %{}, authorize?: false)
    dir = Path.join(System.tmp_dir!(), "longx-wsrpc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "README.md"), "# hi\n")
    File.write!(Path.join(dir, "lib/a.ex"), "a\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    project =
      Projects.create_project!(%{
        name: "WS #{System.unique_integer([:positive])}",
        root_path: dir
      })

    %{dir: dir, id: project.id, project: project}
  end

  defp rpc(conn, action, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", Jason.encode!(Map.put(params, "action", action)))
    |> json_response(200)
  end

  test "files: list, read, write, create, rename, delete", %{conn: conn, id: id, dir: dir} do
    assert %{"success" => true, "data" => entries} =
             rpc(conn, "list_files", %{
               "fields" => ["name", "path", "kind", "size"],
               "input" => %{"projectId" => id, "path" => ""}
             })

    assert [
             %{"name" => "lib", "kind" => "dir"},
             %{"name" => "README.md", "kind" => "file", "size" => 5}
           ] = entries

    assert %{"success" => true, "data" => %{"content" => "# hi\n", "binary" => false}} =
             rpc(conn, "read_file", %{
               "fields" => ["path", "content", "size", "binary", "truncated"],
               "input" => %{"projectId" => id, "path" => "README.md"}
             })

    assert %{"success" => true} =
             rpc(conn, "write_file", %{
               "input" => %{"projectId" => id, "path" => "README.md", "content" => "# edited\n"}
             })

    assert File.read!(Path.join(dir, "README.md")) == "# edited\n"

    assert %{"success" => true, "data" => %{"path" => "lib/b.ex", "kind" => "file"}} =
             rpc(conn, "create_entry", %{
               "fields" => ["path", "kind"],
               "input" => %{"projectId" => id, "path" => "lib/b.ex", "kind" => "file"}
             })

    assert %{"success" => true, "data" => %{"path" => "lib/c.ex"}} =
             rpc(conn, "rename_entry", %{
               "fields" => ["path"],
               "input" => %{"projectId" => id, "from" => "lib/b.ex", "to" => "lib/c.ex"}
             })

    assert %{"success" => true} =
             rpc(conn, "delete_entry", %{"input" => %{"projectId" => id, "path" => "lib/c.ex"}})

    refute File.exists?(Path.join(dir, "lib/c.ex"))

    # errors are structured, on the path field
    assert %{"success" => false, "errors" => [%{"fields" => ["path"]}]} =
             rpc(conn, "read_file", %{
               "fields" => ["path"],
               "input" => %{"projectId" => id, "path" => "../etc/passwd"}
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["path"]}]} =
             rpc(conn, "read_file", %{
               "fields" => ["path"],
               "input" => %{"projectId" => id, "path" => "nope.txt"}
             })
  end

  test "git: changes → file diff → commit some → history → show → branches → remote sync", %{
    conn: conn,
    id: id,
    dir: dir
  } do
    :ok = Git.init(dir)
    {:ok, base} = Git.commit_all(dir, "base")
    File.write!(Path.join(dir, "README.md"), "# two\n")
    File.write!(Path.join(dir, "new.txt"), "n\n")

    assert %{
             "success" => true,
             "data" => %{
               "repository" => true,
               "changes" => changes,
               "branch" => branch,
               "ahead" => nil
             }
           } =
             rpc(conn, "git_changes", %{
               "fields" => ["repository", "changes", "branch", "ahead", "behind"],
               "input" => %{"projectId" => id}
             })

    assert [
             %{"path" => "README.md", "status" => "modified"},
             %{"path" => "new.txt", "status" => "untracked"}
           ] = changes

    assert is_binary(branch)

    assert %{"success" => true, "data" => %{"binary" => false, "diff" => diff}} =
             rpc(conn, "git_file_diff", %{
               "fields" => ["binary", "diff"],
               "input" => %{"projectId" => id, "path" => "README.md"}
             })

    assert diff =~ "+# two"

    assert %{"success" => true, "data" => %{"sha" => sha}} =
             rpc(conn, "git_commit", %{
               "fields" => ["sha"],
               "input" => %{
                 "projectId" => id,
                 "paths" => ["README.md"],
                 "message" => "readme\n\nbody"
               }
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["paths"]}]} =
             rpc(conn, "git_commit", %{
               "fields" => ["sha"],
               "input" => %{"projectId" => id, "paths" => ["README.md"], "message" => "again"}
             })

    assert %{
             "success" => true,
             "data" => [%{"sha" => ^sha, "subject" => "readme"}, %{"sha" => ^base}]
           } =
             rpc(conn, "git_log", %{
               "fields" => ["sha", "subject", "author", "at"],
               "input" => %{"projectId" => id, "limit" => 10, "skip" => 0}
             })

    assert %{
             "success" => true,
             "data" => %{
               "subject" => "readme",
               "body" => "body",
               "files" => [%{"path" => "README.md", "status" => "modified"}]
             }
           } =
             rpc(conn, "git_show", %{
               "fields" => ["sha", "subject", "body", "author", "at", "parents", "files"],
               "input" => %{"projectId" => id, "sha" => sha}
             })

    assert %{"success" => true, "data" => %{"diff" => diff}} =
             rpc(conn, "git_commit_file_diff", %{
               "fields" => ["diff", "binary"],
               "input" => %{"projectId" => id, "sha" => sha, "path" => "README.md"}
             })

    assert diff =~ "+# two"

    assert %{"success" => true} =
             rpc(conn, "git_discard", %{"input" => %{"projectId" => id, "paths" => ["new.txt"]}})

    refute File.exists?(Path.join(dir, "new.txt"))

    assert %{"success" => true, "data" => %{"sha" => ^base}} =
             rpc(conn, "git_undo_commit", %{"fields" => ["sha"], "input" => %{"projectId" => id}})

    assert %{"success" => true, "data" => %{"sha" => _}} =
             rpc(conn, "git_commit", %{
               "fields" => ["sha"],
               "input" => %{
                 "projectId" => id,
                 "paths" => ["README.md"],
                 "message" => "readme again"
               }
             })

    # branches
    assert %{"success" => true, "data" => %{"current" => current, "branches" => [_]}} =
             rpc(conn, "git_branches", %{
               "fields" => ["current", "branches", "stashes"],
               "input" => %{"projectId" => id}
             })

    assert %{"success" => true} =
             rpc(conn, "git_create_branch", %{
               "input" => %{"projectId" => id, "name" => "feature"}
             })

    File.write!(Path.join(dir, "README.md"), "# wip\n")
    # a change that does not conflict rides along with a plain switch (git's rule)…
    assert %{"success" => true} =
             rpc(conn, "git_switch", %{"input" => %{"projectId" => id, "name" => current}})

    assert File.read!(Path.join(dir, "README.md")) == "# wip\n"
    # …`stash: true` sets it aside first, and the stash can come back
    assert %{"success" => true} =
             rpc(conn, "git_switch", %{
               "input" => %{"projectId" => id, "name" => "feature", "stash" => true}
             })

    assert File.read!(Path.join(dir, "README.md")) == "# two\n"

    assert %{
             "success" => true,
             "data" => %{"current" => "feature", "stashes" => [%{"message" => _}]}
           } =
             rpc(conn, "git_branches", %{
               "fields" => ["current", "stashes"],
               "input" => %{"projectId" => id}
             })

    assert %{"success" => true} = rpc(conn, "git_stash_pop", %{"input" => %{"projectId" => id}})
    assert File.read!(Path.join(dir, "README.md")) == "# wip\n"

    assert %{"success" => true} =
             rpc(conn, "git_discard", %{"input" => %{"projectId" => id, "paths" => ["README.md"]}})

    assert %{"success" => true} =
             rpc(conn, "git_switch", %{"input" => %{"projectId" => id, "name" => current}})

    assert %{"success" => true} =
             rpc(conn, "git_delete_branch", %{
               "input" => %{"projectId" => id, "name" => "feature"}
             })

    # remote: a bare repo on disk
    remote =
      Path.join(System.tmp_dir!(), "longx-wsrpc-remote-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(remote) end)
    {:ok, _} = Git.run(["init", "-q", "--bare", remote])

    assert %{"success" => true} =
             rpc(conn, "git_set_remote", %{
               "input" => %{"projectId" => id, "name" => "origin", "url" => remote}
             })

    assert %{"success" => true} = rpc(conn, "git_push", %{"input" => %{"projectId" => id}})

    assert %{
             "success" => true,
             "data" => %{
               "ahead" => 0,
               "behind" => 0,
               "remotes" => [%{"name" => "origin", "url" => ^remote}]
             }
           } =
             rpc(conn, "git_changes", %{
               "fields" => ["ahead", "behind", "remotes"],
               "input" => %{"projectId" => id}
             })

    assert %{"success" => true} = rpc(conn, "git_fetch", %{"input" => %{"projectId" => id}})
    assert %{"success" => true} = rpc(conn, "git_pull", %{"input" => %{"projectId" => id}})
  end

  test "git on a directory that is no repository says so", %{conn: conn, id: id} do
    assert %{"success" => true, "data" => %{"repository" => false, "changes" => []}} =
             rpc(conn, "git_changes", %{
               "fields" => ["repository", "changes"],
               "input" => %{"projectId" => id}
             })

    assert %{"success" => false, "errors" => [%{"fields" => ["projectId"]}]} =
             rpc(conn, "git_log", %{"fields" => ["sha"], "input" => %{"projectId" => id}})
  end
end
