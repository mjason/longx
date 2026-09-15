defmodule Longx.Exec.PolicyTest do
  use ExUnit.Case, async: true

  alias Longx.Exec.Policy

  # what codex 0.154 sends for a workspace-write thread without network
  # (captured from the real binary in the exec-server spike)
  @workspace_write %{
    "cwd" => "file:///home/mj/proj",
    "permissions" => %{
      "type" => "managed",
      "network" => "restricted",
      "file_system" => %{
        "type" => "restricted",
        "entries" => [
          %{"access" => "read", "path" => %{"type" => "special", "value" => %{"kind" => "root"}}},
          %{
            "access" => "write",
            "path" => %{"type" => "special", "value" => %{"kind" => "project_roots"}}
          },
          %{
            "access" => "write",
            "path" => %{"type" => "special", "value" => %{"kind" => "slash_tmp"}}
          },
          %{
            "access" => "write",
            "path" => %{"type" => "special", "value" => %{"kind" => "tmpdir"}}
          },
          %{
            "access" => "read",
            "missing_path_behavior" => "skip",
            "path" => %{
              "type" => "special",
              "value" => %{"kind" => "project_roots", "subpath" => ".git"}
            }
          },
          %{
            "access" => "read",
            "missing_path_behavior" => "skip",
            "path" => %{
              "type" => "special",
              "value" => %{"kind" => "project_roots", "subpath" => ".agents"}
            }
          },
          %{
            "access" => "read",
            "missing_path_behavior" => "skip",
            "path" => %{
              "type" => "special",
              "value" => %{"kind" => "project_roots", "subpath" => ".codex"}
            }
          },
          %{"access" => "write", "path" => %{"type" => "path", "path" => "file:///data/sets"}}
        ]
      }
    },
    "workspaceRoots" => ["file:///home/mj/proj"],
    "useLegacyLandlock" => false,
    "windowsSandboxLevel" => "disabled"
  }

  defp ctx, do: [tmpdir: "/tmp/t1", exists?: fn p -> p in ["/home/mj/proj/.git"] end]

  test "a workspace-write context: writable roots, the read-only pockets inside them, no network" do
    {:ok, policy} = Policy.parse(@workspace_write, ctx())

    assert policy.kind == :restricted
    assert policy.network == :restricted
    assert policy.cwd == "/home/mj/proj"
    assert Policy.writable_roots(policy) == ["/data/sets", "/home/mj/proj", "/tmp", "/tmp/t1"]
    # .agents / .codex do not exist and skip; .git exists and stays read-only
    assert Policy.read_only_paths(policy) == ["/home/mj/proj/.git"]
    assert Policy.sandboxed?(policy)
  end

  test "allowed?/3 answers what a file operation may do" do
    {:ok, policy} = Policy.parse(@workspace_write, ctx())

    assert Policy.allowed?(policy, "/home/mj/proj/lib/a.ex", :write)
    assert Policy.allowed?(policy, "/home/mj/proj", :write)
    assert Policy.allowed?(policy, "/tmp/x", :write)
    assert Policy.allowed?(policy, "/data/sets/a.csv", :write)
    refute Policy.allowed?(policy, "/home/mj/proj/.git/config", :write)
    refute Policy.allowed?(policy, "/home/mj/other", :write)
    refute Policy.allowed?(policy, "/etc/passwd", :write)
    assert Policy.allowed?(policy, "/etc/passwd", :read)
    assert Policy.allowed?(policy, "/home/mj/proj/.git/config", :read)
    # a prefix is not a directory boundary
    refute Policy.allowed?(policy, "/home/mj/proj2/x", :write)
  end

  test "a path granted read and write at once is writable, not a read-only pocket (what request_permissions sends)" do
    ctx =
      put_in(@workspace_write, ["permissions", "file_system", "entries"], [
        %{"access" => "read", "path" => %{"type" => "special", "value" => %{"kind" => "root"}}},
        %{
          "access" => "write",
          "path" => %{"type" => "special", "value" => %{"kind" => "project_roots"}}
        },
        %{
          "access" => "read",
          "path" => %{"type" => "path", "path" => "file:///home/mj/.cache/uv"}
        },
        %{
          "access" => "write",
          "path" => %{"type" => "path", "path" => "file:///home/mj/.cache/uv"}
        }
      ])

    {:ok, policy} = Policy.parse(ctx, ctx())
    assert Policy.writable_roots(policy) == ["/home/mj/.cache/uv", "/home/mj/proj"]
    assert Policy.read_only_paths(policy) == []
    assert Policy.allowed?(policy, "/home/mj/.cache/uv/x", :write)
    assert Policy.allowed?(policy, "/home/mj/.cache/uv", :write)
  end

  test "read-only: nothing writable" do
    ctx =
      put_in(@workspace_write, ["permissions", "file_system", "entries"], [
        %{"access" => "read", "path" => %{"type" => "special", "value" => %{"kind" => "root"}}}
      ])

    {:ok, policy} = Policy.parse(ctx, ctx())
    assert Policy.writable_roots(policy) == []
    assert Policy.sandboxed?(policy)
    refute Policy.allowed?(policy, "/home/mj/proj/a", :write)
  end

  test "full access: root writable, not sandboxed; network follows the profile" do
    ctx =
      @workspace_write
      |> put_in(["permissions", "file_system", "entries"], [
        %{"access" => "write", "path" => %{"type" => "special", "value" => %{"kind" => "root"}}}
      ])
      |> put_in(["permissions", "network"], "enabled")

    {:ok, policy} = Policy.parse(ctx, ctx())
    refute Policy.sandboxed?(policy)
    assert policy.network == :enabled
    assert Policy.allowed?(policy, "/etc/x", :write)
  end

  test "disabled and external profiles are not sandboxed" do
    {:ok, disabled} =
      Policy.parse(put_in(@workspace_write, ["permissions"], %{"type" => "disabled"}), ctx())

    refute Policy.sandboxed?(disabled)
    assert disabled.network == :enabled
    assert Policy.allowed?(disabled, "/anything", :write)

    {:ok, external} =
      Policy.parse(
        put_in(@workspace_write, ["permissions"], %{
          "type" => "external",
          "network" => "restricted"
        }),
        ctx()
      )

    refute Policy.sandboxed?(external)
    assert external.network == :restricted
  end

  test "no context at all (codex asked for an unsandboxed run) is the open policy" do
    {:ok, policy} = Policy.parse(nil, ctx())
    refute Policy.sandboxed?(policy)
    assert policy.network == :enabled
    assert Policy.allowed?(policy, "/anything", :write)
  end

  test "an unknown shape is refused, not silently opened" do
    assert {:error, _} = Policy.parse(%{"permissions" => %{"type" => "whatever"}}, ctx())

    assert {:error, _} =
             Policy.parse(%{"cwd" => "nope", "permissions" => %{"type" => "disabled"}}, ctx())
  end
end
