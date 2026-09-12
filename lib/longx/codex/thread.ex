defmodule Longx.Codex.Thread do
  @moduledoc """
  The thread-level API on top of `Longx.Codex.Connection`: start/resume a
  thread, send a turn, steer or interrupt it, answer approvals, and read or
  subscribe to its `Longx.Codex.ThreadState`.

  This is the one place snake_case options are turned into codex's
  camelCase/kebab-case wire values. Every function takes `conn:` (default
  `Longx.Codex.Connection`, the node-wide connection).
  """

  alias Longx.Codex.{Connection, ThreadState}

  @type approval_policy :: :never | :on_request | :untrusted
  @type sandbox :: :read_only | :workspace_write | :danger_full_access
  @type decision :: :accept | :accept_for_session | :decline | :cancel
  @type start_option ::
          {:cwd, Path.t()}
          | {:approval_policy, approval_policy}
          | {:sandbox, sandbox}
          | {:model_context_window, pos_integer}
          | {:conn, GenServer.server()}

  @approval_policies %{never: "never", on_request: "on-request", untrusted: "untrusted"}
  @sandboxes %{
    read_only: "read-only",
    workspace_write: "workspace-write",
    danger_full_access: "danger-full-access"
  }
  @decisions %{
    accept: "accept",
    accept_for_session: "acceptForSession",
    decline: "decline",
    cancel: "cancel"
  }

  @doc "Starts a thread; its `ThreadState` is created by the connection on `thread/started`."
  @spec start([start_option]) :: {:ok, String.t()} | {:error, term}
  def start(opts) do
    with {:ok, %{"thread" => %{"id" => thread_id}}} <-
           Connection.request(conn(opts), "thread/start", start_params(opts)),
         # so callers can subscribe/snapshot right away; thread/started fills it in
         {:ok, _} <- ThreadState.ensure(thread_id) do
      {:ok, thread_id}
    end
  end

  @doc "Resumes a stored thread and rebuilds its `ThreadState` from `thread/read`."
  @spec resume(String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def resume(thread_id, opts \\ []) do
    conn = conn(opts)

    with {:ok, _} <- Connection.request(conn, "thread/resume", %{"threadId" => thread_id}),
         {:ok, read} <-
           Connection.request(conn, "thread/read", %{
             "threadId" => thread_id,
             "includeTurns" => true
           }),
         {:ok, _} <- ThreadState.ensure(thread_id),
         :ok <- ThreadState.backfill(thread_id, read) do
      {:ok, thread_id}
    end
  end

  @doc "Starts a turn with a text message. Returns the turn id; progress arrives on the thread topic."
  @spec send(String.t(), String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def send(thread_id, text, opts \\ []) do
    params = %{"threadId" => thread_id, "input" => [%{"type" => "text", "text" => text}]}

    with {:ok, %{"turn" => %{"id" => turn_id}}} <-
           Connection.request(conn(opts), "turn/start", params) do
      {:ok, turn_id}
    end
  end

  @doc "Adds input to the in-flight turn without starting a new one."
  @spec steer(String.t(), String.t(), String.t(), keyword) :: :ok | {:error, term}
  def steer(thread_id, turn_id, text, opts \\ []) do
    params = %{
      "threadId" => thread_id,
      "expectedTurnId" => turn_id,
      "input" => [%{"type" => "text", "text" => text}]
    }

    with {:ok, _} <- Connection.request(conn(opts), "turn/steer", params), do: :ok
  end

  @spec interrupt(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def interrupt(thread_id, turn_id, opts \\ []) do
    with {:ok, _} <-
           Connection.request(conn(opts), "turn/interrupt", %{
             "threadId" => thread_id,
             "turnId" => turn_id
           }),
         do: :ok
  end

  @doc "Answers a pending approval (`item/commandExecution/requestApproval` / `item/fileChange/requestApproval`)."
  @spec respond(term, decision, keyword) :: :ok | {:error, :unknown_request}
  def respond(request_id, decision, opts \\ []) when is_map_key(@decisions, decision) do
    Connection.respond(conn(opts), request_id, decision(decision))
  end

  @doc "Answers any pending server request with a raw result map."
  @spec respond_raw(term, map, keyword) :: :ok | {:error, :unknown_request}
  def respond_raw(request_id, result, opts \\ []),
    do: Connection.respond(conn(opts), request_id, result)

  @spec snapshot(String.t()) :: ThreadState.snapshot()
  def snapshot(thread_id) do
    {:ok, _} = ThreadState.ensure(thread_id)
    ThreadState.snapshot(thread_id)
  end

  @spec subscribe(String.t()) :: :ok | {:error, term}
  def subscribe(thread_id), do: ThreadState.subscribe(thread_id)

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(thread_id), do: ThreadState.unsubscribe(thread_id)

  ## Wire mapping (pure)

  @doc false
  @spec start_params([start_option]) :: map
  def start_params(opts) do
    base = %{
      "cwd" => Keyword.fetch!(opts, :cwd),
      "approvalPolicy" =>
        Map.fetch!(@approval_policies, Keyword.get(opts, :approval_policy, :on_request)),
      "sandbox" => Map.fetch!(@sandboxes, Keyword.get(opts, :sandbox, :workspace_write))
    }

    case Keyword.get(opts, :model_context_window) do
      nil -> base
      window -> Map.put(base, "config", %{"model_context_window" => window})
    end
  end

  @doc false
  @spec decision(decision) :: map
  def decision(decision), do: %{"decision" => Map.fetch!(@decisions, decision)}

  defp conn(opts), do: Keyword.get(opts, :conn, Connection)
end
