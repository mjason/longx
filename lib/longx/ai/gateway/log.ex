defmodule Longx.AI.Gateway.Log do
  @moduledoc """
  The gateway's memory of its last requests (1000 by default; `config
  :longx, Longx.AI.Gateway.Log, keep:`), in an ETS table owned by this
  process: what codex asked for — the model, the reasoning effort and
  summary, the tools, the input size, codex's own metadata (thread, turn,
  request kind) — and what came of it (status, duration, error). Settings →
  请求记录 lists it; it is the first place to look when a level or a model
  on the screen does not match what the provider sees. Nothing persists.
  """

  use GenServer

  @table :longx_gateway_log
  @default_keep 1000

  @type entry :: %{
          id: pos_integer,
          at: String.t(),
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          request_kind: String.t() | nil,
          model: String.t() | nil,
          upstream_id: String.t() | nil,
          provider: String.t() | nil,
          effort: String.t() | nil,
          summary: String.t() | nil,
          tools: [String.t()],
          input_items: non_neg_integer,
          input_chars: non_neg_integer,
          instructions_chars: non_neg_integer,
          max_output_tokens: integer | nil,
          status: integer | nil,
          duration_ms: integer | nil,
          error: String.t() | nil
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "How many entries are kept."
  @spec keep() :: pos_integer
  def keep, do: :longx |> Application.get_env(__MODULE__, []) |> Keyword.get(:keep, @default_keep)

  @doc "Records a request as it starts; `target` names what it resolved to (nil when refused)."
  @spec begin(map, map | nil) :: pos_integer
  def begin(body, target) when is_map(body) do
    GenServer.call(__MODULE__, {:begin, entry(body, target)})
  end

  @doc "Records the outcome of a request begun earlier."
  @spec finish(pos_integer, %{status: integer | nil, error: String.t() | nil}) :: :ok
  def finish(id, outcome), do: GenServer.call(__MODULE__, {:finish, id, outcome})

  @doc "The newest `n` entries, newest first."
  @spec recent(pos_integer) :: [entry]
  def recent(n \\ 100) do
    @table
    |> :ets.select_reverse([{{:"$1", :"$2", :_}, [], [:"$2"]}], n)
    |> case do
      {entries, _} -> entries
      :"$end_of_table" -> []
    end
  end

  def clear, do: GenServer.call(__MODULE__, :clear)

  defp entry(body, target) do
    meta = body["client_metadata"] || %{}
    turn_meta = decode(meta["x-codex-turn-metadata"])
    input = List.wrap(body["input"])

    %{
      id: nil,
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      thread_id: meta["thread_id"],
      turn_id: meta["turn_id"],
      request_kind: turn_meta["request_kind"],
      model: body["model"],
      upstream_id: target && target[:upstream_id],
      provider: target && target[:provider],
      effort: get_in(body, ["reasoning", "effort"]),
      summary: get_in(body, ["reasoning", "summary"]),
      tools: body["tools"] |> List.wrap() |> Enum.map(&tool_name/1) |> Enum.reject(&is_nil/1),
      input_items: length(input),
      input_chars: input |> Jason.encode!() |> byte_size(),
      instructions_chars: body["instructions"] |> to_string() |> String.length(),
      max_output_tokens: body["max_output_tokens"],
      status: nil,
      duration_ms: nil,
      error: nil,
      started: System.monotonic_time(:millisecond)
    }
  end

  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(%{"type" => type}) when is_binary(type), do: type
  defp tool_name(_), do: nil

  defp decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :protected, read_concurrency: true])
    {:ok, %{seq: 0}}
  end

  @impl true
  def handle_call({:begin, entry}, _from, %{seq: seq} = state) do
    id = seq + 1
    :ets.insert(@table, {id, Map.drop(%{entry | id: id}, [:started]), entry.started})
    trim()
    {:reply, id, %{state | seq: id}}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  def handle_call({:finish, id, outcome}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, entry, started}] ->
        finished = %{
          entry
          | status: outcome[:status],
            error: outcome[:error],
            duration_ms: System.monotonic_time(:millisecond) - started
        }

        :ets.insert(@table, {id, finished, started})

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  defp trim do
    excess = :ets.info(@table, :size) - keep()

    if excess > 0 do
      # the oldest entries go (the table is ordered by id)
      Enum.reduce_while(1..excess, :ets.first(@table), fn
        _, :"$end_of_table" ->
          {:halt, :"$end_of_table"}

        _, key ->
          next = :ets.next(@table, key)
          :ets.delete(@table, key)
          {:cont, next}
      end)
    end

    :ok
  end
end
