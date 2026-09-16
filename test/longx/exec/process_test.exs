defmodule Longx.Exec.ProcessTest do
  # real OS processes, independent of each other
  use ExUnit.Case, async: true

  alias Longx.Exec.Process, as: ExecProcess

  defp start!(argv, over \\ []) do
    spec =
      Keyword.merge(
        [
          id: "p-#{System.unique_integer([:positive])}",
          argv: argv,
          cwd: File.cwd!(),
          env: %{},
          notify: self()
        ],
        over
      )

    start_supervised!({ExecProcess, spec}, id: spec[:id])
  end

  defp sh(script), do: ["sh", "-c", script]

  test "output, exit and close arrive as notifications with one sequence; read/4 answers the same" do
    id = "p-out"
    pid = start!(sh("echo out; echo err 1>&2; exit 3"), id: id)

    assert_receive {:exec_process, ^id, "process/output",
                    %{"seq" => s1, "stream" => stream1, "chunk" => c1}},
                   5_000

    assert_receive {:exec_process, ^id, "process/output",
                    %{"seq" => s2, "stream" => stream2, "chunk" => c2}},
                   5_000

    assert_receive {:exec_process, ^id, "process/exited",
                    %{"seq" => s3, "exitCode" => 3, "sandboxDenied" => false}},
                   5_000

    assert_receive {:exec_process, ^id, "process/closed", %{"seq" => s4}}, 5_000
    assert [s1, s2, s3, s4] == [1, 2, 3, 4]

    assert Enum.sort([{stream1, Base.decode64!(c1)}, {stream2, Base.decode64!(c2)}]) ==
             [{"stderr", "err\n"}, {"stdout", "out\n"}]

    assert {:ok,
            %{
              "chunks" => chunks,
              "nextSeq" => 5,
              "exited" => true,
              "exitCode" => 3,
              "closed" => true,
              "sandboxDenied" => false
            }} =
             ExecProcess.read(pid, 0, nil, 0)

    assert length(chunks) == 2
    assert {:ok, %{"chunks" => [%{"seq" => 2}]}} = ExecProcess.read(pid, 1, nil, 0)
  end

  test "read/4 waits up to wait_ms for output" do
    pid = start!(sh("sleep 0.3; echo late"))
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{"chunks" => [%{"chunk" => chunk}]}} = ExecProcess.read(pid, 0, nil, 5_000)
    assert Base.decode64!(chunk) == "late\n"
    assert System.monotonic_time(:millisecond) - started >= 250

    # nothing new within the window: an empty answer at the deadline
    assert {:ok, %{"chunks" => [], "exited" => exited}} = ExecProcess.read(pid, 99, nil, 100)
    assert is_boolean(exited)
  end

  test "max_bytes bounds one answer, the next read continues from nextSeq" do
    pid = start!(sh("printf aaaa; sleep 0.1; printf bbbb; sleep 0.1; printf cccc"))
    id = :sys.get_state(pid).id
    assert_receive {:exec_process, ^id, "process/closed", _}, 5_000

    assert {:ok, %{"chunks" => [first], "nextSeq" => next}} = ExecProcess.read(pid, 0, 4, 0)
    assert Base.decode64!(first["chunk"]) == "aaaa"
    assert {:ok, %{"chunks" => rest}} = ExecProcess.read(pid, next - 1, nil, 0)
    assert Enum.map_join(rest, &Base.decode64!(&1["chunk"])) == "bbbbcccc"
  end

  test "stdin: writes reach a pipe_stdin process once per write id; closed otherwise" do
    pid = start!(["cat"], pipe_stdin: true)
    assert ExecProcess.write(pid, "hello\n", "w1") == :accepted
    assert ExecProcess.write(pid, "hello\n", "w1") == :accepted
    assert {:ok, %{"chunks" => [%{"chunk" => chunk}]}} = ExecProcess.read(pid, 0, nil, 5_000)
    assert Base.decode64!(chunk) == "hello\n"
    assert ExecProcess.terminate(pid) == true

    closed = start!(["cat"])
    assert ExecProcess.write(closed, "x", "w2") == :stdin_closed
  end

  test "the environment and cwd are the command's" do
    id = "p-env"
    pid = start!(sh("echo $FOO; pwd"), id: id, env: %{"FOO" => "bar"}, cwd: "/tmp")
    # two lines may come as two chunks: read once everything is in
    assert_receive {:exec_process, ^id, "process/closed", _}, 5_000
    assert {:ok, %{"chunks" => chunks}} = ExecProcess.read(pid, 0, nil, 0)
    assert Enum.map_join(chunks, &Base.decode64!(&1["chunk"])) =~ "bar\n/tmp"
  end

  test "interrupt reaches the process group; terminate kills it and reports whether it was running" do
    id = "p-int"
    # a line first: the interrupt must find the command running (on a slow
    # runner a signal sent right after start landed before `sleep` existed)
    pid = start!(sh("echo up; sleep 30"), id: id)
    assert_receive {:exec_process, ^id, "process/output", _}, 5_000
    :ok = ExecProcess.signal(pid, :interrupt)
    assert_receive {:exec_process, ^id, "process/exited", %{"exitCode" => code}}, 5_000
    assert code == 130
    assert ExecProcess.terminate(pid) == false

    id2 = "p-term"
    pid2 = start!(sh("sleep 30"), id: id2)
    assert ExecProcess.terminate(pid2) == true
    assert_receive {:exec_process, ^id2, "process/exited", %{"exitCode" => code}}, 10_000
    assert code in [143, 137]
    assert_receive {:exec_process, ^id2, "process/closed", _}, 5_000
  end

  test "tty: the command runs on a terminal, its output is the pty stream, stdin is open" do
    id = "p-tty"
    pid = start!(sh("[ -t 0 ] && echo on-a-tty; read x; echo read:$x"), id: id, tty: true)
    assert ExecProcess.write(pid, "typed\n", "w1") == :accepted
    assert_receive {:exec_process, ^id, "process/closed", _}, 10_000
    {:ok, %{"chunks" => chunks, "exitCode" => 0}} = ExecProcess.read(pid, 0, nil, 0)
    assert Enum.all?(chunks, &(&1["stream"] == "pty"))
    output = Enum.map_join(chunks, &Base.decode64!(&1["chunk"]))
    assert output =~ "on-a-tty"
    assert output =~ "read:typed"
  end

  test "a sandboxed failure that smells like a denial is flagged" do
    id = "p-denied"

    start!(sh("echo 'touch: cannot touch x: Read-only file system' 1>&2; exit 1"),
      id: id,
      sandbox: :bwrap
    )

    assert_receive {:exec_process, ^id, "process/exited",
                    %{"exitCode" => 1, "sandboxDenied" => true}},
                   5_000

    id = "p-plain"
    start!(sh("echo 'Read-only file system' 1>&2; exit 1"), id: id)
    assert_receive {:exec_process, ^id, "process/exited", %{"sandboxDenied" => false}}, 5_000
  end

  test "sandbox_denied?/3 follows codex's heuristic" do
    assert ExecProcess.sandbox_denied?(:bwrap, 1, "Permission denied")
    assert ExecProcess.sandbox_denied?(:bwrap, 159, "")
    refute ExecProcess.sandbox_denied?(:bwrap, 0, "permission denied")
    refute ExecProcess.sandbox_denied?(:none, 1, "permission denied")
    refute ExecProcess.sandbox_denied?(:bwrap, 127, "command not found")
    refute ExecProcess.sandbox_denied?(:bwrap, 1, "no such file")
  end
end
