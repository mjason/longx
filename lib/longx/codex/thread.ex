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
          | {:writable_roots, [Path.t()]}
          | {:multi_agent, boolean}
          | {:auto_review, boolean}
          | {:developer_instructions, String.t()}
          | {:tools, [module | String.t()]}
          | {:conn, GenServer.server()}

  # codex's own on-request: the model asks for what a command needs
  # (`with_additional_permissions`, `request_permissions`, `require_escalated`)
  # and the person grants it in the chat; codex never widens the sandbox by
  # itself — a denied command is reported to the model, which asks
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
  model row says *now*, not what it was started with. **The access mode must
  be given again** (`sandbox:`, `approval_policy:`, `cwd:`) and so must
  `developer_instructions:`: codex does not take them from the stored
  thread — a resume without them runs on its defaults (read-only here)
  while the caller still believes the mode it recorded.
  """
  @spec resume(String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def resume(thread_id, opts \\ []) do
    conn = Keyword.fetch!(opts, :conn)

    params =
      %{"threadId" => thread_id}
      |> put_if("cwd", Keyword.get(opts, :cwd))
      |> put_if(
        "sandbox",
        opts |> Keyword.get(:sandbox) |> then(&(&1 && Map.fetch!(@sandboxes, &1)))
      )
      |> put_if(
        "approvalPolicy",
        opts |> Keyword.get(:approval_policy) |> then(&(&1 && Map.fetch!(@approval_policies, &1)))
      )
      |> put_if("developerInstructions", Keyword.get(opts, :developer_instructions))
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

  @doc """
  Overrides a denial of codex's automatic approval review
  (`thread/approveGuardianDeniedAction`): the denied action goes back to
  codex as approved by the person, which puts a developer note in the
  thread's context — the model may retry the action on its next turn and
  the reviewer sees the authorization. The review item is marked
  `userApproved` in the ThreadState. Only a denied review can be approved.
  """
  @spec approve_denied_review(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def approve_denied_review(thread_id, review_id, opts \\ []) do
    with {:ok, item} <- denied_review(thread_id, review_id),
         {:ok, conn} <- conn(thread_id, opts),
         {:ok, _} <-
           Connection.request(conn, "thread/approveGuardianDeniedAction", %{
             "threadId" => thread_id,
             "event" => guardian_event(item)
           }) do
      ThreadState.ingest(thread_id, "item/autoApprovalReview/userApproved", %{
        "threadId" => thread_id,
        "reviewId" => review_id
      })
    end
  end

  defp denied_review(thread_id, review_id) do
    case ThreadState.Store.get_item(thread_id, review_id) do
      %{"type" => "autoApprovalReview", "review" => %{"status" => "denied"}} = item -> {:ok, item}
      %{"type" => "autoApprovalReview"} -> {:error, :not_denied}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The stored review item as codex's core `GuardianAssessmentEvent`: the
  app-server reports reviews in its v2 shape (camelCase, `unifiedExec`) but
  takes the approval in the core one (snake_case keys and enum values).
  """
  @spec guardian_event(map) :: map
  def guardian_event(%{"id" => id} = item) do
    review = Map.get(item, "review", %{})

    %{
      "id" => id,
      "status" => review["status"],
      "risk_level" => review["riskLevel"],
      "user_authorization" => review["userAuthorization"],
      "rationale" => review["rationale"],
      "turn_id" => item["turnId"],
      "target_item_id" => item["targetItemId"],
      "decision_source" => item["decisionSource"],
      "started_at_ms" => item["startedAtMs"],
      "completed_at_ms" => item["completedAtMs"],
      "action" => snake_action(item["action"])
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  # keys snake_cased at every level; the tag values (`type`, `source`, a
  # special path's `value`) are codex enums that change case with the shape,
  # the rest stay as they are. A file-system profile is either the legacy
  # read/write lists or entries in core — the v2 shape carries both when the
  # lists suffice, and core refuses the mix.
  defp snake_action(%{} = map) do
    map
    |> Map.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new(fn
      {key, value} when key in ["type", "source", "value"] and is_binary(value) ->
        {key, Macro.underscore(value)}

      {"fileSystem", %{} = fs} ->
        {"file_system", snake_file_system(fs)}

      {key, value} ->
        {Macro.underscore(key), snake_action(value)}
    end)
  end

  defp snake_action(list) when is_list(list), do: Enum.map(list, &snake_action/1)
  defp snake_action(other), do: other

  defp snake_file_system(fs) do
    case Map.take(fs, ["read", "write"]) |> Map.reject(fn {_, v} -> is_nil(v) end) do
      legacy when map_size(legacy) > 0 -> legacy
      _ -> fs |> Map.drop(["read", "write"]) |> snake_action()
    end
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
    {method, params} = pending(request_id, opts)
    respond_raw(request_id, decision_for(decision, method, params), opts)
  end

  # the request as codex sent it, when the thread is known
  defp pending(request_id, opts) do
    case Keyword.get(opts, :thread_id) do
      nil ->
        {nil, %{}}

      thread_id ->
        thread_id
        |> ThreadState.Store.requests()
        |> Enum.find_value({nil, %{}}, fn %{id: id, method: method, params: params} ->
          if to_string(id) == to_string(request_id), do: {method, params}
        end)
    end
  end

  @permissions_request "item/permissions/requestApproval"

  @doc """
  The answer to send for one of our decisions, given the request. A
  **permissions request** (the `request_permissions` tool) is answered with
  the grant: `accept` gives what was asked for the turn, `accept_for_session`
  for the session, `decline` / `cancel` nothing. A **command approval** is
  answered with what its `availableDecisions` offers: codex lists
  `acceptWithExecpolicyAmendment` (allow this command from now on, an
  execpolicy rule) where it offers no `acceptForSession`, so "always allow"
  takes whichever is there; "decline" is `cancel` when that is the only
  refusal on offer. A request that lists nothing gets the plain words.
  """
  @spec decision_for(decision, String.t() | nil, map) :: map
  def decision_for(decision, @permissions_request, params) do
    case decision do
      :accept ->
        %{"permissions" => params["permissions"] || %{}, "scope" => "turn"}

      :accept_for_session ->
        %{"permissions" => params["permissions"] || %{}, "scope" => "session"}

      _ ->
        %{"permissions" => %{}, "scope" => "turn"}
    end
  end

  def decision_for(decision, _method, params) do
    offered = List.wrap(params["availableDecisions"])
    names = Enum.map(offered, fn d -> if is_map(d), do: hd(Map.keys(d)), else: d end)

    amendment =
      Enum.find(offered, &(is_map(&1) and Map.has_key?(&1, "acceptWithExecpolicyAmendment")))

    cond do
      names == [] ->
        decision(decision)

      (decision == :accept_for_session and amendment) && "acceptForSession" not in names ->
        %{"decision" => amendment}

      decision == :decline and "decline" not in names and "cancel" in names ->
        %{"decision" => "cancel"}

      true ->
        decision(decision)
    end
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

  defp roots_or_nil([]), do: nil
  defp roots_or_nil(roots), do: roots

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
        |> put_if("writableRoots", roots_or_nil(Keyword.get(opts, :writable_roots, [])))
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

    # extra places the workspace-write sandbox may write, on top of codex's
    # cwd / /tmp / $TMPDIR: caches (~/.cache for uv, pip, npm…) and the GPU
    # device nodes — bwrap's minimal /dev has none, a `--bind` brings them in
    config =
      put_if(
        config,
        "sandbox_workspace_write.writable_roots",
        roots_or_nil(Keyword.get(opts, :writable_roots, []))
      )

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

    # codex's Guardian: every approval request goes to a read-only reviewer
    # sub-session (the thread's model) instead of the person — `user` is
    # codex's default, written explicitly so a project that turned it off
    # never inherits a home's setting
    config =
      case Keyword.fetch(opts, :auto_review) do
        {:ok, true} -> Map.put(config, "approvals_reviewer", "auto_review")
        {:ok, false} -> Map.put(config, "approvals_reviewer", "user")
        :error -> config
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
