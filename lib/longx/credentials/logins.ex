defmodule Longx.Credentials.Logins do
  @moduledoc """
  The OAuth2 logins in flight: a `state` the browser will bring back to
  `/callback/credentials`, with the PKCE verifier, the redirect URI it was
  started with and whom to tell. In ETS under this process (in the tree);
  an entry lives `ttl_ms` (15 minutes) — a login nobody finished is
  forgotten, a state is taken once.
  """

  use GenServer

  @table __MODULE__
  @ttl_ms :timer.minutes(15)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @type login :: %{
          required(:credential_id) => String.t(),
          required(:verifier) => String.t() | nil,
          required(:redirect_uri) => String.t(),
          optional(:notify) => pid | nil,
          optional(:thread_id) => String.t() | nil,
          optional(:at) => integer
        }

  @doc "Remembers a login under its state."
  @spec put(String.t(), login) :: :ok
  def put(state, %{} = login), do: GenServer.call(@table, {:put, state, login})

  @doc "Takes the login for a state (once); `:error` for an unknown or expired one."
  @spec take(String.t()) :: {:ok, login} | :error
  def take(state), do: GenServer.call(@table, {:take, state})

  @doc "How many logins wait (tests)."
  @spec count() :: non_neg_integer
  def count, do: :ets.info(@table, :size)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, state, login}, _from, s) do
    prune()
    :ets.insert(@table, {state, Map.put(login, :at, now())})
    {:reply, :ok, s}
  end

  def handle_call({:take, state}, _from, s) do
    case :ets.take(@table, state) do
      [{_, login}] -> {:reply, if(fresh?(login), do: {:ok, login}, else: :error), s}
      [] -> {:reply, :error, s}
    end
  end

  defp prune do
    cutoff = now() - @ttl_ms
    :ets.select_delete(@table, [{{:_, %{at: :"$1"}}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp fresh?(%{at: at}), do: now() - at <= @ttl_ms
  defp now, do: System.monotonic_time(:millisecond)
end
