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
  alias Longx.Codex.Tool.{Context, Registry}

  @type approval_policy :: :never | :on_request | :untrusted
  @type sandbox :: :read_only | :workspace_write | :danger_full_access
  @type decision :: :accept | :accept_for_session | :decline | :cancel
  @type web_search :: :hosted | :standalone | :disabled
  @type start_option ::
          {:cwd, Path.t()}
          | {:approval_policy, approval_policy}
          | {:sandbox, sandbox}
          | {:model, String.t()}
          | {:model_context_window, pos_integer}
          | {:reasoning_effort, String.t()}
          | {:reasoning_summary, atom}
          | {:web_search, web_search}
          | {:tools, [module | String.t()]}
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
    params = %{"threadId" => thread_id} |> put_model(Keyword.get(opts, :model))

    with {:ok, _} <- Connection.request(conn, "thread/resume", params),
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

  @doc """
  Starts a turn with a text message. Returns the turn id; progress arrives
  on the thread topic. `model:` (a `Longx.AI.Model` slug), `effort:` and
  `summary:` (reasoning) apply to this and subsequent turns.
  """
  @spec send(String.t(), String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def send(thread_id, text, opts \\ []) do
    with {:ok, %{"turn" => %{"id" => turn_id}}} <-
           Connection.request(conn(opts), "turn/start", turn_params(thread_id, text, opts)) do
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

  @doc """
  Removes `turn_id` and every later turn from the conversation
  (`thread/revert`) and from the `ThreadState`. Pass the ids of the dropped
  turns as `turn_ids:` when you know them (codex does not report them);
  otherwise every ThreadState item from `turn_id` on is dropped by order.
  """
  @spec revert(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def revert(thread_id, turn_id, opts \\ []) do
    params = %{"threadId" => thread_id, "beforeTurnId" => turn_id}

    with {:ok, _} <- Connection.request(conn(opts), "thread/revert", params),
         {:ok, _} <- ThreadState.ensure(thread_id) do
      turn_ids = Keyword.get_lazy(opts, :turn_ids, fn -> turns_from(thread_id, turn_id) end)
      ThreadState.drop_turns(thread_id, turn_ids)
    end
  end

  # the reverted turn and everything that arrived after it, from the projection
  defp turns_from(thread_id, turn_id) do
    ThreadState.snapshot(thread_id).items
    |> Enum.map(& &1["turnId"])
    |> Enum.uniq()
    |> Enum.drop_while(&(&1 != turn_id))
  end

  @doc """
  Forks the thread into a new one (`thread/fork`): history up to and
  including `last_turn_id:` (all of it when omitted), optionally with a
  different `model:` and the same model settings as `start/1`. Returns the
  new thread id.
  """
  @spec fork(String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def fork(thread_id, opts \\ []) do
    with {:ok, %{"thread" => %{"id" => new_id}}} <-
           Connection.request(conn(opts), "thread/fork", fork_params(thread_id, opts)),
         {:ok, _} <- ThreadState.ensure(new_id) do
      {:ok, new_id}
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

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
      # paginated history is what thread/revert requires (experimental field; experimentalApi is on)
      "historyMode" => "paginated",
      "approvalPolicy" =>
        Map.fetch!(@approval_policies, Keyword.get(opts, :approval_policy, :on_request)),
      "sandbox" => Map.fetch!(@sandboxes, Keyword.get(opts, :sandbox, :workspace_write))
    }

    base =
      base
      # a Longx.AI.Model slug; absent means codex's configured placeholder (global default)
      |> put_model(Keyword.get(opts, :model))
      |> put_config(opts)

    selection = Keyword.get_lazy(opts, :tools, &Longx.AI.enabled_tool_names/0)

    case dynamic_tools(selection, %Context{cwd: base["cwd"]}) do
      [] -> base
      specs -> Map.put(base, "dynamicTools", specs)
    end
  end

  @doc false
  @spec turn_params(String.t(), String.t(), keyword) :: map
  def turn_params(thread_id, text, opts) do
    %{"threadId" => thread_id, "input" => [%{"type" => "text", "text" => text}]}
    |> put_model(Keyword.get(opts, :model))
    |> put_if("effort", Keyword.get(opts, :effort))
    |> put_if("summary", opts |> Keyword.get(:summary) |> wire_atom())
  end

  @doc false
  @spec fork_params(String.t(), keyword) :: map
  def fork_params(thread_id, opts) do
    %{"threadId" => thread_id}
    |> put_if("lastTurnId", Keyword.get(opts, :last_turn_id))
    |> put_model(Keyword.get(opts, :model))
    |> put_config(opts)
  end

  # Per-thread config overrides: the same dotted keys as `codex -c key=value`.
  @config_keys [
    model_context_window: "model_context_window",
    reasoning_effort: "model_reasoning_effort",
    reasoning_summary: "model_reasoning_summary"
  ]

  # `web_search` is the mode (live = allowed); with the standalone feature on
  # and a provider that `supports_standalone_web_search`, codex offers its
  # `web.run` tool instead of the provider-hosted one.
  @web_search_config %{
    hosted: %{"web_search" => "live", "features.standalone_web_search" => false},
    standalone: %{"web_search" => "live", "features.standalone_web_search" => true},
    disabled: %{"web_search" => "disabled", "features.standalone_web_search" => false}
  }

  defp put_config(params, opts) do
    config =
      for {opt, key} <- @config_keys,
          {:ok, value} <- [Keyword.fetch(opts, opt)],
          into: %{},
          do: {key, wire_atom(value)}

    config =
      case Keyword.get(opts, :web_search) do
        nil -> config
        mode -> Map.merge(config, Map.fetch!(@web_search_config, mode))
      end

    if map_size(config) == 0, do: params, else: Map.put(params, "config", config)
  end

  # enum-like options travel as strings; booleans/numbers/strings as they are
  defp wire_atom(value) when is_boolean(value) or is_nil(value), do: value
  defp wire_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp wire_atom(value), do: value

  # Elixir tools offered to the model on this thread (see `Longx.Codex.Tool`).
  # The caller picks them (`"ns.name"` strings or modules); without a choice
  # the globally enabled set from the DB applies — never "everything".
  defp dynamic_tools([], _ctx), do: []

  defp dynamic_tools(selection, ctx) when is_list(selection),
    do: Registry.specs(ctx, only: selection)

  defp put_model(params, nil), do: params
  defp put_model(params, model), do: Map.put(params, "model", model)

  @doc false
  @spec decision(decision) :: map
  def decision(decision), do: %{"decision" => Map.fetch!(@decisions, decision)}

  defp conn(opts), do: Keyword.get(opts, :conn, Connection)
end
