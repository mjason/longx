defmodule Longx.ShimTest do
  # Every test spawns real OS processes; they are independent so async is safe.
  use ExUnit.Case, async: true

  alias Longx.Shim

  @moduletag :shim

  defp sh(script), do: ["sh", "-c", script]

  defp os_alive?(pid), do: signal_0(Integer.to_string(pid))
  defp group_alive?(pgid), do: signal_0("-#{pgid}")

  defp signal_0(target),
    do: match?({_, 0}, System.cmd("kill", ["-0", "--", target], stderr_to_stdout: true))

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end

  defp read_all(shim, acc \\ []) do
    case Shim.read(shim) do
      {:ok, data} -> read_all(shim, [data | acc])
      :eof -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  describe "resource guards (Linux)" do
    test "stats/1 sums the child's process tree; empty after exit" do
      {:ok, shim} =
        Shim.start_link(
          sh("python3 -c 'import time; b = bytearray(32*1024*1024); time.sleep(30)' & sleep 30")
        )

      assert eventually(fn ->
               match?(
                 {:ok, %{processes: n, rss_bytes: rss}} when n >= 3 and rss >= 32 * 1024 * 1024,
                 Shim.stats(shim)
               )
             end)

      assert {:ok, %{cpu_ms: cpu}} = Shim.stats(shim)
      assert is_integer(cpu) and cpu >= 0

      :ok = Shim.kill(shim, 1_000)
      assert {:ok, _} = Shim.await_exit(shim, 5_000)
    end

    test "oom_score_adj: is inherited by the child" do
      beam_before = File.read!("/proc/self/oom_score_adj")
      {:ok, shim} = Shim.start_link(["sleep", "30"], oom_score_adj: 500)
      pid = Shim.os_pid(shim)
      assert File.read!("/proc/#{pid}/oom_score_adj") |> String.trim() == "500"
      # the BEAM itself is untouched
      assert File.read!("/proc/self/oom_score_adj") == beam_before
      :ok = Shim.kill(shim, 1_000)
      assert {:ok, _} = Shim.await_exit(shim, 5_000)
    end

    test "memory_limit: makes allocations fail inside the tree, not in the BEAM" do
      {:ok, %{status: status, stdout: out}} =
        Shim.run(["python3", "-c", "b = bytearray(512*1024*1024); print('allocated')"],
          memory_limit: 256 * 1024 * 1024,
          stderr: :disable
        )

      refute out =~ "allocated"
      refute status == 0
    end

    test "invalid guard options are rejected up front" do
      assert {:error, {:invalid_option, {:oom_score_adj, 5000}}} =
               Shim.start_link(["true"], oom_score_adj: 5000)

      assert {:error, {:invalid_option, {:memory_limit, -1}}} =
               Shim.start_link(["true"], memory_limit: -1)
    end
  end

  describe "environment" do
    test "env_clear: the child gets exactly the given environment, nothing of the BEAM's" do
      System.put_env("LONGX_SHIM_PROBE", "leak")
      on_exit(fn -> System.delete_env("LONGX_SHIM_PROBE") end)

      assert {:ok, %{stdout: inherited}} =
               Shim.run(sh("echo $LONGX_SHIM_PROBE $ONLY"), env: %{"ONLY" => "1"})

      assert inherited == "leak 1\n"

      assert {:ok, %{stdout: clean}} =
               Shim.run(sh("echo $LONGX_SHIM_PROBE $ONLY $PATH"),
                 env: %{"ONLY" => "1", "PATH" => "/usr/bin:/bin"},
                 env_clear: true
               )

      assert clean == "1 /usr/bin:/bin\n"
    end
  end

  describe "pty" do
    test "pty: the child has a controlling terminal, its output is one stream, stdin stays open" do
      {:ok, shim} =
        Shim.start_link(
          sh("tty; [ -t 0 ] && [ -t 2 ] && echo is-a-tty; read line; echo got:$line"),
          pty: true
        )

      :ok = Shim.write(shim, "hello\n")
      assert {:ok, 0} = Shim.await_exit(shim, 10_000, close_streams: false)
      out = read_all(shim)
      assert out =~ ~r{/dev/(pts/\d+|ttys\d+)}
      assert out =~ "is-a-tty"
      assert out =~ "got:hello"
      # a terminal echoes what is typed; stderr is merged into it
      assert Shim.read_stderr(shim) == :eof
    end
  end

  describe "stdout" do
    test "reads output until eof and reports exit status" do
      {:ok, shim} = Shim.start_link(["echo", "hello"])
      assert {:ok, "hello\n"} = Shim.read(shim)
      assert :eof = Shim.read(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
    end

    test "read honours max size" do
      {:ok, shim} = Shim.start_link(["echo", "0123456789"])
      assert {:ok, "0123"} = Shim.read(shim, 4)
      assert {:ok, "456789\n"} = Shim.read(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
    end

    test "only one read may be pending per stream" do
      {:ok, shim} = Shim.start_link(["sleep", "5"])
      task = Task.async(fn -> Shim.read(shim, 10, 2_000) end)
      Process.sleep(50)
      assert {:error, :pending_read} = Shim.read(shim)
      Shim.kill(shim, 0)
      assert :eof = Task.await(task)
    end

    test "close_stdout yields eof and stops consuming output" do
      {:ok, shim} = Shim.start_link(sh("yes | head -c 100000"))
      assert {:ok, _} = Shim.read(shim, 10)
      assert :ok = Shim.close_stdout(shim)
      assert :eof = Shim.read(shim)
      assert {:ok, _} = Shim.await_exit(shim)
    end
  end

  describe "stdin" do
    test "round-trips through cat and closes cleanly" do
      {:ok, shim} = Shim.start_link(["cat"])
      assert :ok = Shim.write(shim, "abc")
      assert {:ok, "abc"} = Shim.read(shim)
      assert :ok = Shim.close_stdin(shim)
      assert :eof = Shim.read(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
    end

    test "large writes are chunked and back-pressured, nothing is lost" do
      payload = :crypto.strong_rand_bytes(1_000_000)
      {:ok, shim} = Shim.start_link(["cat"])

      writer =
        Task.async(fn ->
          :ok = Shim.write(shim, payload, 30_000)
          :ok = Shim.close_stdin(shim)
        end)

      assert read_all(shim) == payload
      assert :ok = Task.await(writer, 30_000)
      assert {:ok, 0} = Shim.await_exit(shim)
    end

    test "writing after close_stdin is an error" do
      {:ok, shim} = Shim.start_link(["cat"])
      :ok = Shim.close_stdin(shim)
      assert {:error, :closed} = Shim.write(shim, "late")
      assert {:ok, 0} = Shim.await_exit(shim)
    end
  end

  describe "stderr" do
    test "is a separate demand-driven stream by default" do
      {:ok, shim} = Shim.start_link(sh("echo out; echo err 1>&2"))
      assert {:ok, "err\n"} = Shim.read_stderr(shim)
      assert :eof = Shim.read_stderr(shim)
      assert {:ok, "out\n"} = Shim.read(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
    end

    test ":disable answers eof immediately" do
      {:ok, shim} = Shim.start_link(sh("echo err 1>&2"), stderr: :disable)
      assert :eof = Shim.read_stderr(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
    end

    test ":redirect_to_stdout merges it into stdout" do
      {:ok, shim} = Shim.start_link(sh("echo err 1>&2"), stderr: :redirect_to_stdout)
      assert {:ok, "err\n"} = Shim.read(shim)
      assert :eof = Shim.read_stderr(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
    end
  end

  describe "process environment" do
    test "passes env and cd" do
      dir = System.tmp_dir!() |> Path.join("longx-shim-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, shim} = Shim.start_link(sh("echo $FOO; pwd"), env: [{"FOO", "bar"}], cd: dir)
      assert read_all(shim) == "bar\n#{Path.expand(dir)}\n"
      assert {:ok, 0} = Shim.await_exit(shim)
    end

    test "rejects a missing command without crashing the caller" do
      assert {:error, {:command_not_found, "/definitely/not/here"}} =
               Shim.start_link(["/definitely/not/here"])

      assert {:error, {:command_not_found, "no-such-binary-xyz"}} =
               Shim.start_link(["no-such-binary-xyz"])
    end

    test "rejects an invalid cd" do
      assert {:error, {:invalid_cd, "/nope/nope"}} = Shim.start_link(["true"], cd: "/nope/nope")
    end

    test "exposes the child's os pid" do
      {:ok, shim} = Shim.start_link(["sleep", "30"])
      pid = Shim.os_pid(shim)
      assert is_integer(pid) and pid > 0
      assert os_alive?(pid)
      :ok = Shim.kill(shim, 0)
      assert {:ok, _} = Shim.await_exit(shim)
      assert eventually(fn -> not os_alive?(pid) end)
    end
  end

  describe "exit status" do
    test "non-zero code" do
      {:ok, shim} = Shim.start_link(sh("exit 7"))
      assert {:ok, 7} = Shim.await_exit(shim)
    end

    test "await_exit times out while the child runs" do
      {:ok, shim} = Shim.start_link(["sleep", "30"])
      assert {:error, :timeout} = Shim.await_exit(shim, 100)
      # grace 0: TERM and KILL go out back to back, either may land first
      :ok = Shim.kill(shim, 0)
      assert {:ok, status} = Shim.await_exit(shim)
      assert status in [137, 143]
    end

    test "await_exit closes unread streams and the server stops normally" do
      {:ok, shim} = Shim.start_link(["echo", "unread"])
      ref = Process.monitor(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
      assert_receive {:DOWN, ^ref, :process, ^shim, :normal}, 2_000
    end

    test "await_exit with close_streams: false keeps the output for a reader that comes later" do
      {:ok, shim} = Shim.start_link(["echo", "kept"])
      assert {:ok, 0} = Shim.await_exit(shim, 5_000, close_streams: false)
      # the child is gone, its output is still to be had
      assert {:ok, "kept\n"} = Shim.read(shim)
      assert :eof = Shim.read(shim)
      ref = Process.monitor(shim)
      assert :eof = Shim.read_stderr(shim)
      assert_receive {:DOWN, ^ref, :process, ^shim, :normal}, 2_000
    end

    test "run/2 never loses a fast command's output, however the scheduler orders things" do
      for _ <- 1..200 do
        assert {:ok, %{status: 0, stdout: "fast\n"}} = Shim.run(["echo", "fast"])
      end
    end

    test "exit status is delivered even when it arrives before output is read" do
      {:ok, shim} = Shim.start_link(["echo", "fast"])
      Process.sleep(100)
      assert {:ok, "fast\n"} = Shim.read(shim)
      assert :eof = Shim.read(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
    end
  end

  describe "termination" do
    test "kill sends SIGTERM first" do
      {:ok, shim} = Shim.start_link(["sleep", "30"])
      :ok = Shim.kill(shim, 5_000)
      assert {:ok, 143} = Shim.await_exit(shim, 2_000)
    end

    test "kill escalates to SIGKILL after the grace period" do
      {:ok, shim} = Shim.start_link(sh(~s(trap "" TERM; sleep 30)))
      Process.sleep(100)
      :ok = Shim.kill(shim, 200)
      assert {:ok, 137} = Shim.await_exit(shim, 3_000)
    end

    test "kill takes the whole process group" do
      {:ok, shim} = Shim.start_link(sh("sleep 30; echo never"))
      pgid = Shim.os_pid(shim)
      Process.sleep(100)
      assert group_alive?(pgid)
      :ok = Shim.kill(shim, 200)
      assert {:ok, _} = Shim.await_exit(shim, 3_000)
      assert eventually(fn -> not group_alive?(pgid) end)
    end

    test "signal is forwarded to the child" do
      {:ok, shim} =
        Shim.start_link(sh(~s(trap "echo got; exit 0" HUP; while :; do sleep 0.05; done)))

      Process.sleep(150)
      :ok = Shim.signal(shim, :hup)
      assert {:ok, "got\n"} = Shim.read(shim)
      assert {:ok, 0} = Shim.await_exit(shim)
    end

    test "the child tree dies with its owner" do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, shim} = Shim.start_link(sh("sleep 30; echo never"))
          send(test_pid, {:started, shim, Shim.os_pid(shim)})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, shim, pgid}, 5_000
      Process.sleep(100)
      assert group_alive?(pgid)

      Process.exit(owner, :kill)

      assert eventually(fn -> not Process.alive?(shim) end)
      assert eventually(fn -> not group_alive?(pgid) end, 250)
    end
  end
end
