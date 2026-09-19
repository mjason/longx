defmodule Longx.System.Memory do
  @moduledoc """
  How much memory the machine has and how much of it is free right now —
  what the command guards and `Longx.System.Pressure` reason with.

  Linux reads `/proc/meminfo` (`MemAvailable`: the kernel's own estimate of
  what can be handed out without swapping — it sees memory the GPU driver
  carved out of RAM, which no process's RSS does). macOS reads `hw.memsize`
  and `vm_stat` (free + inactive + speculative pages). Windows answers nil:
  the guards that need it stay off there and say so. The total is cached
  (it does not change); `available/0` is read every time.
  """

  @type t :: %{total: pos_integer, available: non_neg_integer}

  @doc "Total and available bytes, nil where the platform gives none."
  @spec read() :: t | nil
  def read do
    case :os.type() do
      {:unix, :linux} -> linux()
      {:unix, :darwin} -> darwin()
      _ -> nil
    end
  end

  @doc "The machine's RAM in bytes (cached), nil where unknown."
  @spec total() :: pos_integer | nil
  def total do
    case :persistent_term.get({__MODULE__, :total}, :unread) do
      :unread ->
        total = total_of(read())
        if total, do: :persistent_term.put({__MODULE__, :total}, total)
        total

      total ->
        total
    end
  end

  @doc "Bytes available right now, nil where unknown."
  @spec available() :: non_neg_integer | nil
  def available do
    case read() do
      %{available: a} -> a
      nil -> nil
    end
  end

  defp total_of(%{total: t}), do: t
  defp total_of(nil), do: nil

  defp linux do
    case File.read("/proc/meminfo") do
      {:ok, text} -> parse_meminfo(text)
      _ -> nil
    end
  end

  @doc false
  def parse_meminfo(text) when is_binary(text) do
    kb = fn key ->
      case Regex.run(~r/^#{key}:\s+(\d+) kB/m, text) do
        [_, n] -> String.to_integer(n) * 1024
        _ -> nil
      end
    end

    with total when is_integer(total) <- kb.("MemTotal"),
         available when is_integer(available) <- kb.("MemAvailable") do
      %{total: total, available: available}
    else
      _ -> nil
    end
  end

  defp darwin do
    with {:ok, %{status: 0, stdout: size}} <-
           Longx.Shim.run(["sysctl", "-n", "hw.memsize"], stderr: :disable),
         {total, _} <- Integer.parse(String.trim(size)),
         {:ok, %{status: 0, stdout: stat}} <- Longx.Shim.run(["vm_stat"], stderr: :disable),
         available when is_integer(available) <- parse_vm_stat(stat) do
      %{total: total, available: min(available, total)}
    else
      _ -> nil
    end
  end

  @doc false
  def parse_vm_stat(text) when is_binary(text) do
    with [_, size] <- Regex.run(~r/page size of (\d+) bytes/, text) do
      page = String.to_integer(size)

      pages = fn key ->
        case Regex.run(~r/^Pages #{key}:\s+(\d+)\./m, text) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end
      end

      (pages.("free") + pages.("inactive") + pages.("speculative")) * page
    else
      _ -> nil
    end
  end
end
