defmodule Longx.Exec.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Longx.Exec.{Discovery, PathUri, Policy}

  setup do
    root = Path.join(System.tmp_dir!(), "longx-disc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "skills/foo/agents"))
    File.write!(Path.join(root, "skills/foo/SKILL.md"), "# foo")
    File.write!(Path.join(root, "skills/foo/agents/openai.yaml"), "name: foo")
    File.mkdir_p!(Path.join(root, "skills/bar"))
    File.write!(Path.join(root, "skills/bar/SKILL.md"), "# bar")
    File.mkdir_p!(Path.join(root, ".codex-plugin"))
    File.write!(Path.join(root, ".codex-plugin/plugin.json"), ~s({"name":"root"}))
    File.write!(Path.join(root, ".mcp.json"), ~s({"mcpServers":{}}))
    File.mkdir_p!(Path.join(root, "sub/.claude-plugin"))
    File.write!(Path.join(root, "sub/.claude-plugin/plugin.json"), ~s({"name":"sub"}))
    File.write!(Path.join(root, "big.md"), "x")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, policy} = Policy.parse(nil, [])
    %{root: root, policy: policy}
  end

  test "skills, the root plugin with its mcp config, and every plugin manifest as a namespace", %{
    root: root,
    policy: policy
  } do
    uri = PathUri.from_path(root)

    assert %{"roots" => [discovery]} =
             Discovery.discover(policy, [%{"id" => "r1", "path" => uri}])

    assert discovery["id"] == "r1"
    assert discovery["path"] == uri
    assert discovery["error"] == nil
    assert discovery["warnings"] == []

    assert [
             %{"instructions" => bar, "metadata" => nil},
             %{"instructions" => foo, "metadata" => meta}
           ] = discovery["skills"]

    assert bar == %{
             "path" => PathUri.from_path(Path.join(root, "skills/bar/SKILL.md")),
             "contents" => "# bar"
           }

    assert foo["contents"] == "# foo"

    assert meta == %{
             "path" => PathUri.from_path(Path.join(root, "skills/foo/agents/openai.yaml")),
             "contents" => "name: foo"
           }

    assert %{"manifest" => manifest, "mcpConfig" => mcp, "appsConfig" => nil} =
             discovery["plugin"]

    assert manifest == %{
             "path" => PathUri.from_path(Path.join(root, ".codex-plugin/plugin.json")),
             "contents" => ~s({"name":"root"})
           }

    assert mcp["contents"] == ~s({"mcpServers":{}})

    assert Enum.map(discovery["namespaceManifests"], & &1["contents"]) == [
             ~s({"name":"root"}),
             ~s({"name":"sub"})
           ]
  end

  test "a root that is not a directory is an error on that root only; a missing skill file just leaves a warning",
       %{root: root, policy: policy} do
    assert %{"roots" => [bad, good]} =
             Discovery.discover(policy, [
               %{"id" => "f", "path" => PathUri.from_path(Path.join(root, "big.md"))},
               %{"id" => "d", "path" => PathUri.from_path(Path.join(root, "skills/bar"))}
             ])

    assert bad["error"] =~ "not a directory"
    assert bad["skills"] == []
    assert good["error"] == nil
    assert [%{"instructions" => %{"contents" => "# bar"}}] = good["skills"]
    assert good["plugin"] == nil
    # the nearest ancestor's manifest is the namespace of a nested root
    assert [%{"contents" => ~s({"name":"root"})}] = good["namespaceManifests"]
  end

  test "reads stay within the request's sandbox policy", %{root: root} do
    ctx = %{
      "cwd" => PathUri.from_path(root),
      "workspaceRoots" => [PathUri.from_path(root)],
      "permissions" => %{
        "type" => "managed",
        "network" => "restricted",
        "file_system" => %{
          "type" => "restricted",
          "entries" => [
            %{
              "access" => "deny",
              "path" => %{
                "type" => "path",
                "path" => PathUri.from_path(Path.join(root, "skills/foo"))
              }
            }
          ]
        }
      }
    }

    {:ok, policy} = Policy.parse(ctx, [])

    assert %{"roots" => [d]} =
             Discovery.discover(policy, [%{"id" => "r", "path" => PathUri.from_path(root)}])

    refute Enum.any?(d["skills"], &(&1["instructions"]["contents"] == "# foo"))
    assert Enum.any?(d["warnings"], &(&1 =~ "foo"))
  end
end
