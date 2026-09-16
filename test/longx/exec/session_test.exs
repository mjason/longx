defmodule Longx.Exec.SessionTest do
  use ExUnit.Case, async: true

  alias Longx.Exec.{PathUri, Session}

  # the test process plays the socket: inline replies come back from handle/2,
  # slow ones and process events arrive as messages
  defp session(opts \\ []) do
    # the socket process traps exits (a command that cannot start stops in init)
    Process.flag(:trap_exit, true)

    Session.new(
      Keyword.merge([project_id: "p1", context: fn -> %{sandbox: [], shim: []} end], opts)
    )
  end

  defp request(session, id, method, params \\ %{}),
    do: Session.handle(session, %{"id" => id, "method" => method, "params" => params})

  defp await_reply(id) do
    assert_receive {:exec_out, %{"id" => ^id} = frame}, 10_000
    frame
  end

  @cwd File.cwd!()

  defp start_params(id, argv, over \\ %{}) do
    Map.merge(
      %{
        "processId" => id,
        "argv" => argv,
        "cwd" => PathUri.from_path(@cwd),
        "env" => %{"CODEX_CI" => "1"},
        "envPolicy" => %{
          "inherit" => "core",
          "ignoreDefaultExcludes" => false,
          "exclude" => [],
          "set" => %{},
          "includeOnly" => []
        },
        "tty" => false,
        "pipeStdin" => false,
        "arg0" => nil,
        "sandbox" => %{"cwd" => PathUri.from_path(@cwd), "permissions" => %{"type" => "disabled"}},
        "enforceManagedNetwork" => false
      },
      over
    )
  end

  test "the handshake: initialize answers with a session and the environment, initialized is silent" do
    {s, [reply]} =
      request(session(), 1, "initialize", %{
        "clientName" => "codex-environment",
        "resumeSessionId" => nil
      })

    assert %{"id" => 1, "result" => %{"sessionId" => sid, "environmentInfo" => info}} = reply
    assert is_binary(sid)

    assert %{
             "shell" => %{"name" => name, "path" => path},
             "platformOs" => os,
             "capabilities" => caps
           } = info

    assert name in ["bash", "zsh", "sh"] and File.exists?(path)
    assert os in ["linux", "macos"]

    assert caps == %{
             "networkProxyLaunch" => false,
             "capabilityDiscoverySandbox" => false,
             "environmentConfigRead" => false,
             "httpHeaderEnvVars" => false,
             "sandboxedFileStreaming" => false,
             "shellSnapshotV2" => false
           }

    assert info["userHomeDir"] == PathUri.from_path(System.user_home!())

    assert {_, []} = Session.handle(s, %{"method" => "initialized", "params" => %{}})
    assert {_, [%{"id" => 2, "result" => ^info}]} = request(s, 2, "environment/info")

    assert {_, [%{"id" => 3, "result" => %{"status" => "ready"}}]} =
             request(s, 3, "environment/status")

    # a resumed session keeps its id
    {_, [%{"result" => %{"sessionId" => ^sid}}]} =
      request(s, 4, "initialize", %{"clientName" => "c", "resumeSessionId" => sid})
  end

  test "unknown methods are method-not-found; a bad request is refused, never crashes the session" do
    assert {_, [%{"id" => 1, "error" => %{"code" => -32601}}]} =
             request(session(), 1, "http/request", %{})

    assert {_, [%{"id" => 2, "error" => %{"code" => -32602}}]} =
             request(session(), 2, "process/start", %{"argv" => []})

    assert {_, []} = Session.handle(session(), %{"method" => "whatever/notification"})
  end

  test "process/start runs the command under the session's environment; its events come as frames; read/terminate work by id" do
    s = session()

    {s, [%{"id" => 1, "result" => %{"processId" => "p-1", "sandboxType" => "none"}}]} =
      request(
        s,
        1,
        "process/start",
        start_params("p-1", ["sh", "-c", "echo $CODEX_CI $HOME; echo $DEEPSEEK_API_KEY"])
      )

    assert_receive {:exec_process, "p-1", "process/output", _} = event, 5_000

    assert %{
             "method" => "process/output",
             "params" => %{"processId" => "p-1", "seq" => seq, "stream" => "stdout"}
           } = Session.event_frame(event)

    assert seq >= 1
    assert_receive {:exec_process, "p-1", "process/exited", %{"exitCode" => 0}}, 5_000
    assert_receive {:exec_process, "p-1", "process/closed", _}, 5_000

    # exactly the built environment: codex's overlay, the core variables, no secrets, nothing of the BEAM's
    {:ok, %{"chunks" => chunks}} =
      Longx.Exec.Process.read(Map.fetch!(s.processes, "p-1"), 0, nil, 0)

    assert Enum.map_join(chunks, &Base.decode64!(&1["chunk"])) == "1 #{System.user_home!()}\n\n"

    {s, []} =
      request(s, 2, "process/read", %{
        "processId" => "p-1",
        "afterSeq" => 0,
        "maxBytes" => nil,
        "waitMs" => 100
      })

    # two echo lines may arrive as one chunk or two
    assert %{"result" => %{"chunks" => [_ | _], "closed" => true, "exitCode" => 0}} =
             await_reply(2)

    {s, []} = request(s, 3, "process/read", %{"processId" => "nope", "afterSeq" => 0})
    assert %{"error" => %{"code" => -32600}} = await_reply(3)

    {s, [%{"id" => 4, "result" => %{"running" => false}}]} =
      request(s, 4, "process/terminate", %{"processId" => "p-1"})

    # gone after a terminate of a finished process
    {_s, []} = request(s, 5, "process/read", %{"processId" => "p-1", "afterSeq" => 0})
    assert %{"error" => _} = await_reply(5)
  end

  test "stdin, signal and terminate on a running process" do
    s = session()

    {s, [%{"result" => %{"processId" => "cat"}}]} =
      request(s, 1, "process/start", start_params("cat", ["cat"], %{"pipeStdin" => true}))

    {s, [%{"id" => 2, "result" => %{"status" => "accepted"}}]} =
      request(s, 2, "process/write", %{
        "processId" => "cat",
        "chunk" => Base.encode64("hi\n"),
        "writeId" => "w1"
      })

    assert_receive {:exec_process, "cat", "process/output", %{"chunk" => chunk}}, 5_000
    assert Base.decode64!(chunk) == "hi\n"

    {s, [%{"result" => %{"status" => "unknownProcess"}}]} =
      request(s, 3, "process/write", %{"processId" => "zz", "chunk" => "", "writeId" => "w2"})

    {s, [%{"id" => 4, "result" => %{}}]} =
      request(s, 4, "process/signal", %{"processId" => "cat", "signal" => "interrupt"})

    assert_receive {:exec_process, "cat", "process/exited", _}, 5_000

    {s, [%{"result" => %{"processId" => "sl"}}]} =
      request(s, 5, "process/start", start_params("sl", ["sleep", "30"]))

    {s, [%{"result" => %{"running" => true}}]} =
      request(s, 6, "process/terminate", %{"processId" => "sl"})

    assert_receive {:exec_process, "sl", "process/closed", _} = closed, 10_000
    assert Session.process_count(s) == 2
    # the socket hands the close to the session, which lets a terminated process go
    {s, [%{"method" => "process/closed"}]} = Session.on_message(s, closed)
    assert Session.process_count(s) == 1

    {s, [%{"result" => %{"running" => false}}]} =
      request(s, 7, "process/terminate", %{"processId" => "sl"})

    # cat (interrupted, never terminated) is still held; terminating it now lets it go too
    {s, [%{"result" => %{"running" => false}}]} =
      request(s, 8, "process/terminate", %{"processId" => "cat"})

    assert Session.process_count(s) == 0
  end

  test "a command that cannot start is an error to codex, not a dead session" do
    {_, [%{"id" => 1, "error" => %{"code" => -32603, "message" => message}}]} =
      request(session(), 1, "process/start", start_params("x", ["/nonexistent/program"]))

    assert message =~ "nonexistent"
  end

  test "fs requests and capability discovery go through the request's policy" do
    dir = Path.join(System.tmp_dir!(), "longx-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "skills/s"))
    File.write!(Path.join(dir, "skills/s/SKILL.md"), "# s")
    File.write!(Path.join(dir, "f.txt"), "content")
    on_exit(fn -> File.rm_rf!(dir) end)

    s = session()

    {s, []} =
      request(s, 1, "fs/readFile", %{
        "path" => PathUri.from_path(Path.join(dir, "f.txt")),
        "sandbox" => nil
      })

    assert %{"result" => %{"dataBase64" => data}} = await_reply(1)
    assert Base.decode64!(data) == "content"

    read_only = %{
      "cwd" => PathUri.from_path(dir),
      "permissions" => %{
        "type" => "managed",
        "network" => "restricted",
        "file_system" => %{
          "type" => "restricted",
          "entries" => [
            %{
              "access" => "read",
              "path" => %{"type" => "special", "value" => %{"kind" => "root"}}
            }
          ]
        }
      }
    }

    {s, []} =
      request(s, 2, "fs/writeFile", %{
        "path" => PathUri.from_path(Path.join(dir, "g.txt")),
        "dataBase64" => Base.encode64("g"),
        "sandbox" => read_only
      })

    assert %{"error" => %{"code" => -32600}} = await_reply(2)
    refute File.exists?(Path.join(dir, "g.txt"))

    {s, []} =
      request(s, 3, "fs/getMetadata", %{"path" => PathUri.from_path(dir), "sandbox" => nil})

    assert %{"result" => %{"isDirectory" => true}} = await_reply(3)

    {s, []} =
      request(s, 4, "fs/readDirectory", %{"path" => PathUri.from_path(dir), "sandbox" => nil})

    assert %{"result" => %{"entries" => [_, _]}} = await_reply(4)

    {s, []} =
      request(s, 5, "fs/walk", %{
        "path" => PathUri.from_path(dir),
        "sandbox" => nil,
        "options" => %{
          "maxDepth" => 3,
          "maxDirectories" => 10,
          "maxEntries" => 10,
          "followDirectorySymlinks" => false
        }
      })

    assert %{"result" => %{"entries" => entries}} = await_reply(5)
    assert length(entries) == 4

    {s, []} =
      request(s, 6, "fs/canonicalize", %{
        "path" => PathUri.from_path(Path.join(dir, "skills/../f.txt")),
        "sandbox" => nil
      })

    assert %{"result" => %{"path" => canonical}} = await_reply(6)
    assert canonical == PathUri.from_path(Path.join(dir, "f.txt"))

    {s, [%{"id" => 7, "result" => %{"handleId" => "h1"}}]} =
      request(s, 7, "fs/open", %{
        "handleId" => "h1",
        "path" => PathUri.from_path(Path.join(dir, "f.txt")),
        "sandbox" => nil
      })

    {s, []} = request(s, 8, "fs/readBlock", %{"handleId" => "h1", "offset" => 2, "len" => 3})
    assert %{"result" => %{"chunk" => block, "eof" => false}} = await_reply(8)
    assert Base.decode64!(block) == "nte"
    {s, []} = request(s, 9, "fs/readBlock", %{"handleId" => "h1", "offset" => 5, "len" => 10})
    assert %{"result" => %{"chunk" => tail, "eof" => true}} = await_reply(9)
    assert Base.decode64!(tail) == "nt"
    {s, [%{"id" => 10, "result" => %{}}]} = request(s, 10, "fs/close", %{"handleId" => "h1"})

    {s, [%{"id" => 11, "error" => _}]} =
      request(s, 11, "fs/readBlock", %{"handleId" => "h1", "offset" => 0, "len" => 1})

    {s, []} =
      request(s, 12, "fs/createDirectory", %{
        "path" => PathUri.from_path(Path.join(dir, "a/b")),
        "recursive" => true,
        "sandbox" => nil
      })

    assert %{"result" => %{}} = await_reply(12)

    {s, []} =
      request(s, 13, "fs/copy", %{
        "sourcePath" => PathUri.from_path(Path.join(dir, "f.txt")),
        "destinationPath" => PathUri.from_path(Path.join(dir, "a/f.txt")),
        "recursive" => false,
        "sandbox" => nil
      })

    assert %{"result" => %{}} = await_reply(13)

    {s, []} =
      request(s, 14, "fs/remove", %{
        "path" => PathUri.from_path(Path.join(dir, "a")),
        "recursive" => true,
        "force" => false,
        "sandbox" => nil
      })

    assert %{"result" => %{}} = await_reply(14)
    refute File.exists?(Path.join(dir, "a"))

    {_s, []} =
      request(s, 15, "capabilityRoots/discoverV1", %{
        "roots" => [%{"id" => "r", "path" => PathUri.from_path(dir), "sandbox" => read_only}]
      })

    assert %{
             "result" => %{
               "roots" => [
                 %{"id" => "r", "skills" => [%{"instructions" => %{"contents" => "# s"}}]}
               ]
             }
           } = await_reply(15)
  end

  @tag :host_sandbox
  test "a sandboxed start really runs under bubblewrap: the cwd is writable, the rest is not, no network" do
    dir = Path.join(System.tmp_dir!(), "longx-sbx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    sandbox = %{
      "cwd" => PathUri.from_path(dir),
      "workspaceRoots" => [PathUri.from_path(dir)],
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
            }
          ]
        }
      }
    }

    s = session()

    script =
      "touch here && (touch /etc/longx-nope 2>&1; echo rc=$?) && (cat /proc/self/status | head -1) && cut -d: -f1 /proc/net/dev | tail -n +3"

    {_s, [%{"result" => %{"sandboxType" => "linuxSeccomp"}}]} =
      request(
        s,
        1,
        "process/start",
        start_params("sb", ["sh", "-c", script], %{
          "cwd" => PathUri.from_path(dir),
          "sandbox" => sandbox
        })
      )

    output = collect_output("sb", "")
    assert File.exists?(Path.join(dir, "here"))
    assert output =~ "Read-only file system"
    assert output =~ "rc=1"
    assert output =~ "Name:"
    # only the loopback in an unshared network namespace
    assert output
           |> String.split("\n")
           |> Enum.map(&String.trim/1)
           |> Enum.filter(&(&1 != "" and &1 =~ ~r/^[a-z]/))
           |> Enum.reject(&String.contains?(&1, " "))
           |> Enum.take(-1) == ["lo"]
  end

  defp collect_output(id, acc) do
    receive do
      {:exec_process, ^id, "process/output", %{"chunk" => c}} ->
        collect_output(id, acc <> Base.decode64!(c))

      {:exec_process, ^id, "process/closed", _} ->
        acc

      {:exec_process, ^id, _, _} ->
        collect_output(id, acc)
    after
      10_000 -> flunk("no close; output so far: #{acc}")
    end
  end
end
