defmodule Longx.Computer.Pool do
  @moduledoc "Pins a turn to one computer. Alias failover is allowed only before binding."
  use GenServer
  alias Longx.Computer.{Service, Connection}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def resolve(owner, name), do: GenServer.call(__MODULE__, {:resolve, owner, name})

  def target(name) do
    with {:ok, ids} <- Service.resolve_ids(name) do
      case Enum.find(ids, &(Connection.status(&1).phase == "ready")) do
        nil -> {:error, "No connected computer in the selected alias; connect one in Settings"}
        id -> {:ok, id}
      end
    end
  end

  @impl true
  def init(_), do: {:ok, %{bindings: %{}, refs: %{}}}

  @impl true
  def handle_call({:resolve, {thread, _} = owner, name}, _from, state) do
    case state.bindings[owner] do
      %{name: ^name, id: id, generation: generation} ->
        result =
          if Connection.status(id).phase == "ready" and Connection.generation(id) == generation,
            do: {:ok, id},
            else:
              {:error,
               "The selected computer disconnected or changed; start a new turn and observe. Do not replay input on another machine"}

        {:reply, result, state}

      nil ->
        case target(name) do
          {:ok, id} ->
            Phoenix.PubSub.subscribe(Longx.PubSub, "thread:#{thread}")
            ref = if pid = Longx.Agent.whereis(thread), do: Process.monitor(pid)
            binding = %{name: name, id: id, ref: ref, generation: Connection.generation(id)}
            refs = if ref, do: Map.put(state.refs, ref, owner), else: state.refs

            {:reply, {:ok, id},
             %{state | bindings: Map.put(state.bindings, owner, binding), refs: refs}}

          error ->
            {:reply, error, state}
        end

      _ ->
        {:reply,
         {:error, "Computer alias changed during this turn; start a new turn to switch targets"},
         state}
    end
  end

  @impl true
  def handle_info(
        {:thread, _, "turn/completed", %{"threadId" => thread, "turn" => %{"id" => turn}}},
        state
      ),
      do: {:noreply, drop(state, {thread, turn})}

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, drop(state, state.refs[ref])}

  def handle_info(_, state), do: {:noreply, state}

  defp drop(state, owner) do
    case Map.pop(state.bindings, owner) do
      {nil, _} ->
        state

      {%{ref: ref}, bindings} ->
        if ref, do: Process.demonitor(ref, [:flush])
        {thread, _} = owner

        unless Enum.any?(bindings, fn {{t, _}, _} -> t == thread end),
          do: Phoenix.PubSub.unsubscribe(Longx.PubSub, "thread:#{thread}")

        %{state | bindings: bindings, refs: Map.delete(state.refs, ref)}
    end
  end
end
