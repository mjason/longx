defmodule Longx.Exec.FsTest do
  use ExUnit.Case, async: true

  alias Longx.Exec.{Fs, PathUri, Policy}

  setup do
    root = Path.join(System.tmp_dir!(), "longx-fs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "proj/.git"))
    File.mkdir_p!(Path.join(root, "proj/sub"))
    File.write!(Path.join(root, "proj/a.txt"), "hello")
    File.write!(Path.join(root, "proj/sub/b.txt"), "b")
    File.write!(Path.join(root, "proj/.git/HEAD"), "ref")
    File.write!(Path.join(root, "outside.txt"), "x")
    on_exit(fn -> File.rm_rf!(root) end)

    context = %{
      "cwd" => PathUri.from_path(Path.join(root, "proj")),
      "workspaceRoots" => [PathUri.from_path(Path.join(root, "proj"))],
      "permissions" => %{
        "type" => "managed",
        "network" => "restricted",
        "file_system" => %{
          "type" => "restricted",
          "entries" => [
            %{
              "access" => "read",
              "path" => %{"type" => "special", "value" => %{"kind" => "root"}}
            },
            %{
              "access" => "write",
              "path" => %{"type" => "special", "value" => %{"kind" => "project_roots"}}
            },
            %{
              "access" => "read",
              "missing_path_behavior" => "skip",
              "path" => %{
                "type" => "special",
                "value" => %{"kind" => "project_roots", "subpath" => ".git"}
              }
            }
          ]
        }
      }
    }

    {:ok, policy} = Policy.parse(context, [])

    %{
      root: root,
      proj: Path.join(root, "proj"),
      policy: policy,
      uri: &PathUri.from_path(Path.join(root, &1))
    }
  end

  test "readFile / getMetadata / readDirectory / canonicalize read anywhere the policy allows", %{
    policy: p,
    uri: uri,
    proj: proj
  } do
    assert {:ok, %{"dataBase64" => data}} = Fs.read_file(p, uri.("proj/a.txt"))
    assert Base.decode64!(data) == "hello"
    assert {:ok, %{"dataBase64" => _}} = Fs.read_file(p, uri.("outside.txt"))
    assert {:error, {-32004, _}} = Fs.read_file(p, uri.("proj/missing"))

    assert {:ok,
            %{
              "isDirectory" => true,
              "isFile" => false,
              "isSymlink" => false,
              "size" => _,
              "modifiedAtMs" => ms
            }} =
             Fs.get_metadata(p, uri.("proj/sub"), false)

    assert is_integer(ms) and ms > 0
    assert {:error, {-32004, _}} = Fs.get_metadata(p, uri.("proj/nope"), false)

    assert {:ok, %{"entries" => entries}} = Fs.read_directory(p, uri.("proj"))

    assert Enum.sort_by(entries, & &1["fileName"]) == [
             %{"fileName" => ".git", "isDirectory" => true, "isFile" => false},
             %{"fileName" => "a.txt", "isDirectory" => false, "isFile" => true},
             %{"fileName" => "sub", "isDirectory" => true, "isFile" => false}
           ]

    assert {:ok, %{"path" => canonical}} = Fs.canonicalize(p, uri.("proj/sub/../a.txt"))
    assert canonical == PathUri.from_path(Path.join(proj, "a.txt"))
  end

  test "writes stay inside the writable roots and out of the read-only pockets", %{
    policy: p,
    uri: uri,
    proj: proj
  } do
    assert {:ok, %{}} = Fs.write_file(p, uri.("proj/new.txt"), Base.encode64("n"))
    assert File.read!(Path.join(proj, "new.txt")) == "n"
    assert {:error, {-32600, msg}} = Fs.write_file(p, uri.("outside2.txt"), Base.encode64("n"))
    assert msg =~ "sandbox"
    assert {:error, {-32600, _}} = Fs.write_file(p, uri.("proj/.git/HEAD"), Base.encode64("n"))
    assert File.read!(Path.join(proj, ".git/HEAD")) == "ref"

    assert {:ok, %{}} = Fs.create_directory(p, uri.("proj/x/y"), true)
    assert File.dir?(Path.join(proj, "x/y"))
    assert {:error, {-32600, _}} = Fs.create_directory(p, uri.("elsewhere"), true)

    assert {:ok, %{}} = Fs.copy(p, uri.("proj/a.txt"), uri.("proj/x/a.txt"), false)
    assert File.read!(Path.join(proj, "x/a.txt")) == "hello"
    assert {:error, {-32600, _}} = Fs.copy(p, uri.("proj/a.txt"), uri.("copy.txt"), false)

    assert {:ok, %{}} = Fs.remove(p, uri.("proj/x"), true, false)
    refute File.exists?(Path.join(proj, "x"))
    assert {:error, {-32004, _}} = Fs.remove(p, uri.("proj/x"), true, false)
    assert {:ok, %{}} = Fs.remove(p, uri.("proj/x"), true, true)
    assert {:error, {-32600, _}} = Fs.remove(p, uri.("outside.txt"), false, false)
  end

  test "an open policy writes anywhere", %{uri: uri, root: root} do
    {:ok, open} = Policy.parse(nil, [])
    assert {:ok, %{}} = Fs.write_file(open, uri.("free.txt"), Base.encode64("f"))
    assert File.read!(Path.join(root, "free.txt")) == "f"
  end

  test "walk lists files and directories breadth-first within the limits", %{
    policy: p,
    uri: uri,
    proj: proj
  } do
    options = %{
      "maxDepth" => 6,
      "maxDirectories" => 2000,
      "maxEntries" => 20_000,
      "followDirectorySymlinks" => true,
      "pruneHiddenDirectories" => false
    }

    assert {:ok, %{"entries" => entries, "errors" => [], "truncated" => false}} =
             Fs.walk(p, uri.("proj"), options)

    assert Enum.map(entries, &{&1["path"], &1["kind"]}) == [
             {PathUri.from_path(Path.join(proj, ".git")), "directory"},
             {PathUri.from_path(Path.join(proj, "a.txt")), "file"},
             {PathUri.from_path(Path.join(proj, "sub")), "directory"},
             {PathUri.from_path(Path.join(proj, ".git/HEAD")), "file"},
             {PathUri.from_path(Path.join(proj, "sub/b.txt")), "file"}
           ]

    assert {:ok, %{"entries" => pruned}} =
             Fs.walk(p, uri.("proj"), %{options | "pruneHiddenDirectories" => true})

    refute Enum.any?(pruned, &(&1["path"] =~ "HEAD"))

    assert {:ok, %{"entries" => shallow}} = Fs.walk(p, uri.("proj"), %{options | "maxDepth" => 0})
    assert length(shallow) == 3

    assert {:ok, %{"truncated" => true, "entries" => [_, _]}} =
             Fs.walk(p, uri.("proj"), %{options | "maxEntries" => 2})

    assert {:ok, %{"entries" => []}} = Fs.walk(p, uri.("proj/a.txt"), options)
    assert {:error, {-32600, _}} = Fs.walk(p, uri.("proj"), %{options | "maxEntries" => 0})
  end
end
