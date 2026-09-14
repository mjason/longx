defmodule Longx.Codex.Thread do
  @moduledoc """
  The thread-level API on top of `Longx.Codex.Connection`: start/resume a
  thread, send a turn, steer or interrupt it, answer approvals, and read or
  subscribe to its `Longx.Codex.ThreadState`.

  This is the one place snake_case options are turned into codex's
  camelCase/kebab-case wire values. Every function takes `conn:`; for an
  existing thread it defaults to the connection hosting it
  (`Longx.Codex.Pool.connection_for_thread/1`), so only `start/1` and
  `resume/2` (a thread no running codex has seen yet) need it.
  """

  alias Longx.Codex.{Connection, Pool, ThreadState}
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
          | {:network_access, boolean}
          | {:multi_agent, boolean}
          | {:developer_instructions, String.t()}
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
           Connection.request(Keyword.fetch!(opts, :conn), "thread/start", start_params(opts)),
         # so callers can subscribe/snapshot right away; thread/started fills it in
         {:ok, _} <- ThreadState.ensure(thread_id) do
      {:ok, thread_id}
    end
  end

  @doc """
  Resumes a stored thread and rebuilds its `ThreadState` from `thread/read`.
  Takes the same model / config options as `start/1` (`model_context_window:`,
  `reasoning_effort:`, `web_search:`, …): a resumed thread runs with what the
  model row says *now*, not what it was started with.
  """
  @spec resume(String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def resume(thread_id, opts \\ []) do
    conn = Keyword.fetch!(opts, :conn)

    params =
      %{"threadId" => thread_id}
      |> put_model(Keyword.get(opts, :model))
      |> put_config(opts)

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
    with {:ok, conn} <- conn(thread_id, opts),
         {:ok, %{"turn" => %{"id" => turn_id}}} <-
           Connection.request(conn, "turn/start", turn_params(thread_id, text, opts)) do
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

    with {:ok, conn} <- conn(thread_id, opts),
         {:ok, _} <- Connection.request(conn, "turn/steer", params),
         do: :ok
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

    with {:ok, conn} <- conn(thread_id, opts),
         {:ok, _} <- Connection.request(conn, "thread/revert", params),
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
    with {:ok, conn} <- conn(thread_id, opts),
         {:ok, %{"thread" => %{"id" => new_id}}} <-
           Connection.request(conn, "thread/fork", fork_params(thread_id, opts)),
         {:ok, _} <- ThreadState.ensure(new_id) do
      {:ok, new_id}
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc "Asks codex to compact the thread's context (`thread/compact/start`)."
  @spec compact(String.t(), keyword) :: :ok | {:error, term}
  def compact(thread_id, opts \\ []) do
    with {:ok, conn} <- conn(thread_id, opts),
         {:ok, _} <- Connection.request(conn, "thread/compact/start", %{"threadId" => thread_id}),
         do: :ok
  end

  @typedoc "What a review looks at."
  @type review_target ::
          :uncommitted
          | {:commit, String.t()}
          | {:base_branch, String.t()}
          | {:custom, String.t()}

  @doc """
  Starts codex's code review (`review/start`) as a turn of the thread
  (inline delivery), answering with the turn id like `send/3`.
  """
  @spec review(String.t(), review_target, keyword) :: {:ok, String.t()} | {:error, term}
  def review(thread_id, target, opts \\ []) do
    with {:ok, conn} <- conn(thread_id, opts),
         {:ok, %{"turn" => %{"id" => turn_id}}} <-
           Connection.request(conn, "review/start", review_params(thread_id, target)) do
      {:ok, turn_id}
    end
  end

  @spec review_params(String.t(), review_target) :: map
  def review_params(thread_id, target) do
    %{"threadId" => thread_id, "target" => review_target(target), "delivery" => "inline"}
  end

  defp review_target(:uncommitted), do: %{"type" => "uncommittedChanges"}
  defp review_target({:commit, sha}), do: %{"type" => "commit", "sha" => sha}
  defp review_target({:base_branch, branch}), do: %{"type" => "baseBranch", "branch" => branch}
  defp review_target({:custom, text}), do: %{"type" => "custom", "instructions" => text}

  @spec interrupt(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def interrupt(thread_id, turn_id, opts \\ []) do
    with {:ok, conn} <- conn(thread_id, opts),
         {:ok, _} <-
           Connection.request(conn, "turn/interrupt", %{
             "threadId" => thread_id,
             "turnId" => turn_id
           }),
         do: :ok
  end

  @doc """
  Answers a pending approval (`item/commandExecution/requestApproval` /
  `item/fileChange/requestApproval`). The request lives in one connection:
  pass `conn:` or `thread_id:` (the thread it belongs to).
  """
  @spec respond(term, decision, keyword) :: :ok | {:error, :unknown_request | :no_connection}
  def respond(request_id, decision, opts \\ []) when is_map_key(@decisions, decision) do
    respond_raw(request_id, decision(decision), opts)
  end

  @doc "Answers any pending server request with a raw result map (`conn:` or `thread_id:`)."
  @spec respond_raw(term, map, keyword) :: :ok | {:error, :unknown_request | :no_connection}
  def respond_raw(request_id, result, opts \\ []) do
    with {:ok, conn} <- conn(Keyword.get(opts, :thread_id), opts),
         do: Connection.respond(conn, request_id, result)
  end

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
      # Longx's global memory (and anything else the app wants the model told)
      |> put_if("developerInstructions", Keyword.get(opts, :developer_instructions))

    selection = Keyword.get_lazy(opts, :tools, &Longx.AI.enabled_tool_names/0)

    case dynamic_tools(selection, %Context{cwd: base["cwd"]}) do
      [] -> base
      specs -> Map.put(base, "dynamicTools", specs)
    end
  end

  @doc false
  @spec turn_params(String.t(), String.t(), keyword) :: map
  def turn_params(thread_id, text, opts) do
    # images (data: or http(s): urls) go as their own inputs after the text
    images = for url <- Keyword.get(opts, :images, []), do: %{"type" => "image", "url" => url}

    %{"threadId" => thread_id, "input" => [%{"type" => "text", "text" => text} | images]}
    |> put_model(Keyword.get(opts, :model))
    |> put_if("effort", Keyword.get(opts, :effort))
    |> put_if("summary", opts |> Keyword.get(:summary) |> wire_atom())
    |> put_if(
      "approvalPolicy",
      opts |> Keyword.get(:approval_policy) |> then(&(&1 && Map.fetch!(@approval_policies, &1)))
    )
    |> put_if("sandboxPolicy", sandbox_policy(opts))
  end

  # turn/start's SandboxPolicy (the structured form; thread/start takes the
  # kebab-case name) — codex keeps it for the turns after this one too
  defp sandbox_policy(opts) do
    case Keyword.get(opts, :sandbox) do
      nil ->
        nil

      :read_only ->
        %{"type" => "readOnly"}

      :danger_full_access ->
        %{"type" => "dangerFullAccess"}

      :workspace_write ->
        %{
          "type" => "workspaceWrite",
          "networkAccess" => Keyword.get(opts, :network_access, false)
        }
    end
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

    # only the opt-in is written: codex's default is already "no network"
    config =
      if Keyword.get(opts, :network_access, false),
        do: Map.put(config, "sandbox_workspace_write.network_access", true),
        else: config

    # sub-agents: codex's `spawn_agent` / `wait` / … tools (multi_agent_v2);
    # the `[agents]` limits come from the global config (Longx.Codex.Home)
    config =
      case Keyword.fetch(opts, :multi_agent) do
        {:ok, true} ->
          Map.put(config, "features.multi_agent_v2", true)

        {:ok, false} ->
          config
          |> Map.put("features.multi_agent", false)
          |> Map.put("features.multi_agent_v2", false)

        _ ->
          config
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

  # `conn:` when given, else the connection that hosts the thread
  defp conn(thread_id, opts) do
    case Keyword.fetch(opts, :conn) do
      {:ok, conn} -> {:ok, conn}
      :error when is_binary(thread_id) -> Pool.connection_for_thread(thread_id)
      :error -> {:error, :no_connection}
    end
  end
end
