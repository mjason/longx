defmodule Longx.AI.Gateway.LimiterTest do
  use ExUnit.Case, async: true

  alias Longx.AI.Gateway.Limiter

  defp key, do: "provider-#{System.unique_integer([:positive])}"

  test "nil means unlimited" do
    k = key()
    for _ <- 1..50, do: assert(:ok = Limiter.acquire(k, nil))
    assert Limiter.in_flight(k) == 50
  end

  test "counts in-flight requests per provider and refuses beyond the limit" do
    k = key()
    assert :ok = Limiter.acquire(k, 2)
    assert :ok = Limiter.acquire(k, 2)
    assert :busy = Limiter.acquire(k, 2)
    assert Limiter.in_flight(k) == 2

    :ok = Limiter.release(k)
    assert :ok = Limiter.acquire(k, 2)
    assert Limiter.in_flight(k) == 2
  end

  test "providers are independent" do
    a = key()
    b = key()
    assert :ok = Limiter.acquire(a, 1)
    assert :busy = Limiter.acquire(a, 1)
    assert :ok = Limiter.acquire(b, 1)
  end

  test "release never goes below zero" do
    k = key()
    :ok = Limiter.release(k)
    assert Limiter.in_flight(k) == 0
  end

  test "run/3 releases when the function returns or raises" do
    k = key()
    assert {:ok, :done} = Limiter.run(k, 1, fn -> :done end)
    assert Limiter.in_flight(k) == 0

    assert_raise RuntimeError, fn -> Limiter.run(k, 1, fn -> raise "boom" end) end
    assert Limiter.in_flight(k) == 0

    :ok = Limiter.acquire(k, 1)
    assert :busy = Limiter.run(k, 1, fn -> :never end)
  end
end
