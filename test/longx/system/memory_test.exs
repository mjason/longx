defmodule Longx.System.MemoryTest do
  use ExUnit.Case, async: true

  alias Longx.System.Memory

  test "Linux: total and available read off /proc/meminfo (MemAvailable, the kernel's own estimate)" do
    meminfo = """
    MemTotal:       127600592 kB
    MemFree:          121964 kB
    MemAvailable:    3987200 kB
    Buffers:            1024 kB
    """

    assert Memory.parse_meminfo(meminfo) == %{
             total: 127_600_592 * 1024,
             available: 3_987_200 * 1024
           }

    assert Memory.parse_meminfo("garbage") == nil
  end

  test "macOS: vm_stat's free + inactive + speculative pages times the page size" do
    vm_stat = """
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages free:                               10000.
    Pages active:                            200000.
    Pages inactive:                           50000.
    Pages speculative:                         5000.
    Pages wired down:                        100000.
    """

    assert Memory.parse_vm_stat(vm_stat) == 65_000 * 16_384
    assert Memory.parse_vm_stat("") == nil
  end

  test "on this machine total and available are positive bytes, available below total (nil where unsupported)" do
    case Memory.read() do
      %{total: total, available: available} ->
        assert is_integer(total) and total > 0
        assert is_integer(available) and available > 0 and available <= total
        assert Memory.total() == total

      nil ->
        assert :os.type() == {:win32, :nt}
    end
  end
end
