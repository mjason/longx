defmodule Longx.Chrome.Connection do
  @moduledoc """
  The live extensions: a `LongxWeb.ChromeChannel` process per connected
  browser, registered here by browser id (`Longx.Chrome.Registry`, so a
  gone process is gone from the registry). `call/4` sends one allow-listed
  `chrome.*` command through it and waits for the extension's answer;
  `push/3` sends it a plain event (approval, revocation).
  """

  @registry Longx.Chrome.Registry

  @spec register(String.t(), :pending | :approved) :: :ok | {:error, :taken}
  def register(browser_id, status) do
    case Registry.register(@registry, {:browser, browser_id}, status) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, pid}} when pid == self() ->
        mark_here(browser_id, status)

      {:error, {:already_registered, pid}} ->
        # a stale connection of the same extension (a reconnect that beat the
        # old socket's close): the new one wins once the old process is gone
        ref = Process.monitor(pid)
        send(pid, :superseded)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> Process.demonitor(ref, [:flush])
        end

        case Registry.register(@registry, {:browser, browser_id}, status) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, :taken}
        end
    end
  end

  # only the registering process may change its value: the channel does it on request
  @spec mark(String.t(), :pending | :approved) :: :ok
  def mark(browser_id, status) do
    case pid(browser_id) do
      {:ok, pid, _} -> send(pid, {:mark, status})
      :error -> :ok
    end

    :ok
  end

  @doc false
  def mark_here(browser_id, status) do
    Registry.update_value(@registry, {:browser, browser_id}, fn _ -> status end)
    :ok
  end

  @spec pid(String.t()) :: {:ok, pid, :pending | :approved} | :error
  def pid(browser_id) do
    case Registry.lookup(@registry, {:browser, browser_id}) do
      # the Registry drops a dead owner's key a moment after its DOWN: a
      # channel that just left is offline at once, not until the Registry noticed
      [{pid, status}] -> if Process.alive?(pid), do: {:ok, pid, status}, else: :error
      [] -> :error
    end
  end

  @doc "Connected and approved."
  @spec online?(String.t()) :: boolean
  def online?(browser_id), do: match?({:ok, _, :approved}, pid(browser_id))

  @doc "Connected, approved or not."
  @spec connected?(String.t()) :: boolean
  def connected?(browser_id), do: match?({:ok, _, _}, pid(browser_id))

  @doc """
  One command to the extension — `method` an allow-listed `chrome.*` call,
  `params` its positional arguments — and its answer.
  """
  @spec call(String.t(), String.t(), list, timeout) :: {:ok, term} | {:error, term}
  def call(browser_id, method, params, timeout \\ 30_000) when is_list(params) do
    case pid(browser_id) do
      {:ok, pid, :approved} ->
        try do
          GenServer.call(pid, {:cmd, method, params}, timeout)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, _ -> {:error, :offline}
        end

      {:ok, _pid, :pending} ->
        {:error, :pending}

      :error ->
        {:error, :offline}
    end
  end

  @spec push(String.t(), String.t(), map) :: :ok | {:error, :offline}
  def push(browser_id, event, payload) when is_binary(event) and is_map(payload) do
    case pid(browser_id) do
      {:ok, pid, _} ->
        send(pid, {:push, event, payload})
        :ok

      :error ->
        {:error, :offline}
    end
  end
end
