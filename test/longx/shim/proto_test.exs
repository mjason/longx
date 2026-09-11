defmodule Longx.Shim.ProtoTest do
  use ExUnit.Case, async: true

  alias Longx.Shim.Proto

  describe "host -> shim encoding" do
    test "input carries raw bytes" do
      assert Proto.encode(:input, "abc") == <<1, "abc">>
    end

    test "close_input / close_output / close_stderr have no payload" do
      assert Proto.encode(:close_input) == <<2>>
      assert Proto.encode(:close_output) == <<5>>
      assert Proto.encode(:close_stderr) == <<6>>
    end

    test "send_output / send_stderr carry a big-endian u32 max size" do
      assert Proto.encode(:send_output, 1024) == <<3, 0, 0, 4, 0>>
      assert Proto.encode(:send_stderr, 1) == <<4, 0, 0, 0, 1>>
    end

    test "kill carries the grace period in ms" do
      assert Proto.encode(:kill, 5000) == <<7, 0, 0, 19, 136>>
    end

    test "signal carries the signal number" do
      assert Proto.encode(:signal, 15) == <<8, 0, 0, 0, 15>>
    end

    test "env is length-prefixed KEY=VALUE entries" do
      assert Proto.encode(:env, [{"A", "1"}, {"BB", "22"}]) ==
               <<9, 0, 3, "A=1", 0, 5, "BB=22">>

      assert Proto.encode(:env, []) == <<9>>
    end

    test "env rejects entries that do not fit a u16 length" do
      assert_raise ArgumentError, fn ->
        Proto.encode(:env, [{"K", String.duplicate("v", 70_000)}])
      end
    end
  end

  describe "shim -> host decoding" do
    test "pid" do
      assert Proto.decode(<<16, 0, 0, 48, 57>>) == {:pid, 12345}
    end

    test "output / stderr data" do
      assert Proto.decode(<<17, "hello">>) == {:output, "hello"}
      assert Proto.decode(<<19, "oops">>) == {:stderr, "oops"}
    end

    test "eof markers" do
      assert Proto.decode(<<18>>) == :output_eof
      assert Proto.decode(<<20>>) == :stderr_eof
    end

    test "exit status is a signed i32" do
      assert Proto.decode(<<21, 0, 0, 0, 7>>) == {:exit_status, 7}
      assert Proto.decode(<<21, 255, 255, 255, 255>>) == {:exit_status, -1}
      assert Proto.decode(<<21, 0, 0, 0, 143>>) == {:exit_status, 143}
    end

    test "start error carries a reason" do
      assert Proto.decode(<<22, "exec: not found">>) == {:start_error, "exec: not found"}
    end

    test "send_input credit" do
      assert Proto.decode(<<23>>) == :send_input
    end

    test "unknown tags are reported, not crashed on" do
      assert Proto.decode(<<99, "x">>) == {:unknown, 99, "x"}
    end
  end

  test "max chunk fits one port packet with room for the tag" do
    assert Proto.max_chunk() == 64 * 1024 - 5
  end

  test "protocol version matches the Go shim" do
    {out, 0} = System.cmd(Longx.Shim.executable(), ["-v"])
    assert out == "protocol_version: #{Proto.version()}\n"
  end
end
