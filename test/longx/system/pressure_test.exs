defmodule Longx.System.PressureTest do
  use ExUnit.Case, async: false

  alias Longx.System.Pressure

  test "a sweep tells every registered command whose floor is above the free share; the others are left alone" do
    me = self()

    low =
      spawn_link(fn ->
        :ok = Pressure.register(%{shim: nil, floor: 5, cmd: "low", thread_id: "t1"})
        send(me, :registered)

        receive do
          {:memory_pressure, _} = msg -> send(me, {:low_got, msg})
        end
      end)

    high =
      spawn_link(fn ->
        :ok = Pressure.register(%{shim: nil, floor: 20, cmd: "high", thread_id: "t2"})
        send(me, :registered)

        receive do
          {:memory_pressure, _} = msg -> send(me, {:high_got, msg})
        end
      end)

    assert_receive :registered
    assert_receive :registered
    assert Enum.sort(Enum.map(Pressure.running(), &elem(&1, 0))) == Enum.sort([low, high])

    # 10% free: below 20, above 5
    assert Pressure.sweep(%{total: 1000, available: 100}) == 1
    assert_receive {:high_got, {:memory_pressure, %{percent: 10, available: 100, total: 1000}}}
    refute_receive {:low_got, _}, 100

    # nothing registered with a floor of 0 is ever touched; plenty of memory touches nobody
    assert Pressure.sweep(%{total: 1000, available: 900}) == 0
    assert Pressure.sweep(nil) == 0
  end

  test "the sweep is recorded as a fault so the person sees it happened" do
    me = self()

    spawn_link(fn ->
      :ok = Pressure.register(%{shim: nil, floor: 50, cmd: "echo hi", thread_id: "t3"})
      send(me, :registered)
      receive do: (_ -> :ok)
    end)

    assert_receive :registered
    assert Pressure.sweep(%{total: 1000, available: 100}) == 1
    # the newest fault is this kill (the ring is capped, so only the head is ours to assert on)
    assert [%{kind: :memory, detail: detail} | _] = Longx.System.Faults.recent()
    assert detail =~ "10%"
    assert detail =~ "echo hi"
  end
end
