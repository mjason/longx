defmodule Longx.System.Pairing do
  @moduledoc """
  The one-time code a phone pairs with: six digits, ten minutes, one at a
  time (a new code replaces the old), spent on use. In memory — a restart
  simply asks for a new code.
  """

  use Agent

  @ttl_ms :timer.minutes(10)

  def start_link(_opts), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc "A fresh code, replacing any earlier one."
  @spec new_code() :: %{code: String.t(), expires_at: DateTime.t()}
  def new_code do
    code = (:rand.uniform(1_000_000) - 1) |> Integer.to_string() |> String.pad_leading(6, "0")
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_ms, :millisecond)
    Agent.update(__MODULE__, fn _ -> %{code: code, expires_at: expires_at} end)
    %{code: code, expires_at: expires_at}
  end

  @doc "Spends the code when it is the current, unexpired one."
  @spec redeem(String.t()) :: :ok | :error
  def redeem(code) when is_binary(code) do
    Agent.get_and_update(__MODULE__, fn
      %{code: ^code, expires_at: expires_at} = current ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
          do: {:ok, nil},
          else: {:error, current}

      current ->
        {:error, current}
    end)
  end

  def redeem(_), do: :error
end
