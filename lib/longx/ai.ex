defmodule Longx.AI do
  @moduledoc """
  Model providers, models, and the "which upstream do we talk to" decision
  used by the AI gateway. Codex only knows a placeholder model (`longx`);
  this domain decides what that means.
  """

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  alias Longx.AI.{Model, Provider, SearchProvider, SearchTarget, Target}
  alias Longx.Codex.Tool.Registry

  # The SPA's typed client (settings pages)
  typescript_rpc do
    resource Provider do
      rpc_action :list_providers, :read
      rpc_action :create_provider, :create
      rpc_action :update_provider, :update
    end

    resource Model do
      rpc_action :list_models, :read
      rpc_action :create_model, :create
      rpc_action :update_model, :update
      rpc_action :make_default_model, :make_default
      rpc_action :check_model, :check_model
    end

    resource Longx.AI.Tool do
      rpc_action :list_tools, :catalogue
      rpc_action :set_tool_enabled, :set_enabled
    end
  end

  resources do
    resource Provider do
      define :create_provider, action: :create
      define :update_provider, action: :update
      define :list_providers, action: :read
      define :get_provider_by_slug, action: :by_slug, args: [:slug]
      define :record_provider_error, action: :record_error, args: [:message]
      define :clear_provider_error, action: :clear_error
      define :record_provider_check, action: :record_check, args: [:error]
    end

    resource Model do
      define :create_model, action: :create
      define :update_model, action: :update
      define :list_models, action: :read, default_options: [load: [:provider]]
      define :default_model, action: :default, default_options: [not_found_error?: false]
      define :make_default_model, action: :make_default
      define :get_model_by_slug, action: :by_slug, args: [:slug]
    end

    resource SearchProvider do
      define :create_search_provider, action: :create
      define :update_search_provider, action: :update
      define :list_search_providers, action: :read
      define :get_search_provider_by_slug, action: :by_slug, args: [:slug]

      define :default_search_provider,
        action: :default,
        default_options: [not_found_error?: false]

      define :make_default_search_provider, action: :make_default
    end

    resource Longx.AI.Tool do
      define :create_tool, action: :create
      define :set_tool_enabled, action: :set_enabled
      define :get_tool, action: :by_qualified_name, args: [:namespace, :name]
      define :enabled_tools, action: :enabled
    end
  end

  ## Agent tools: the registry says what exists, the DB says what is on

  @doc """
  Every registered tool with its switch. Syncs the DB to the registry first:
  new tools are inserted disabled, tools gone from the code are removed.
  """
  @spec list_tools() :: {:ok, [map]} | {:error, term}
  def list_tools do
    registered = Registry.all()
    known = MapSet.new(registered, &{&1.namespace, &1.name})

    Enum.each(registered, &create_tool!(%{namespace: &1.namespace, name: &1.name}))

    Longx.AI.Tool
    |> Ash.read!()
    |> Enum.reject(&MapSet.member?(known, {&1.namespace, &1.name}))
    |> Enum.each(&Ash.destroy!/1)

    rows = Longx.AI.Tool |> Ash.read!() |> Map.new(&{{&1.namespace, &1.name}, &1})

    {:ok,
     registered
     |> Enum.sort_by(&{&1.namespace, &1.name})
     |> Enum.map(fn tool ->
       row = Map.fetch!(rows, {tool.namespace, tool.name})

       %{
         id: row.id,
         namespace: tool.namespace,
         name: tool.name,
         qualified_name: "#{tool.namespace}.#{tool.name}",
         description: tool.description,
         input_schema: tool.input_schema,
         enabled: row.enabled
       }
     end)}
  end

  def list_tools! do
    {:ok, tools} = list_tools()
    tools
  end

  @doc "Qualified names (`\"ns.name\"`) of the globally enabled tools — what a thread gets when it does not choose."
  @spec enabled_tool_names() :: [String.t()]
  def enabled_tool_names do
    enabled_tools!()
    |> Enum.map(&"#{&1.namespace}.#{&1.name}")
    |> Enum.filter(&match?({:ok, _}, Registry.fetch_qualified(&1)))
    |> Enum.sort()
  end

  @spec enable_tool(String.t()) :: {:ok, Longx.AI.Tool.t()} | {:error, :unknown_tool | term}
  def enable_tool(qualified_name), do: switch_tool(qualified_name, true)

  @spec disable_tool(String.t()) :: {:ok, Longx.AI.Tool.t()} | {:error, :unknown_tool | term}
  def disable_tool(qualified_name), do: switch_tool(qualified_name, false)

  defp switch_tool(qualified_name, enabled) do
    with {:ok, %{namespace: namespace, name: name}} <- Registry.fetch_qualified(qualified_name),
         {:ok, row} <- create_tool(%{namespace: namespace, name: name}) do
      set_tool_enabled(row, %{enabled: enabled})
    else
      :error -> {:error, :unknown_tool}
      other -> other
    end
  end

  @placeholder_model "longx"

  @doc "The model name codex is configured with; it means \"the global default model\"."
  @spec placeholder_model() :: String.t()
  def placeholder_model, do: @placeholder_model

  @doc """
  The upstream to forward a request to, by the model name codex sent:
  `"longx"` (or nothing) is the global default model, anything else a
  `Longx.AI.Model` slug. Carries the provider's base URL and decrypted key.
  """
  @spec resolve_target(String.t() | nil) ::
          {:ok, Target.t()}
          | {:error,
             :no_default_model | {:unknown_model, String.t()} | {:missing_api_key, String.t()}}
  def resolve_target(nil), do: resolve_target()
  def resolve_target(@placeholder_model), do: resolve_target()

  def resolve_target(slug) when is_binary(slug) do
    case get_model_by_slug(slug) do
      {:ok, %Model{} = model} -> target_for(model)
      {:error, _} -> {:error, {:unknown_model, slug}}
    end
  end

  @doc "The global default model's target."
  @spec resolve_target() ::
          {:ok, Target.t()} | {:error, :no_default_model | {:missing_api_key, String.t()}}
  def resolve_target do
    with {:ok, %Model{} = model} <- fetch_default_model(), do: target_for(model)
  end

  defp target_for(%Model{} = model) do
    with %Model{provider: %Provider{} = provider} <- Ash.load!(model, provider: [:api_key]),
         {:ok, api_key} <- fetch_api_key(provider) do
      {:ok,
       %Target{
         model: model.upstream_id,
         base_url: provider.base_url,
         api_key: api_key,
         context_window: model.context_window,
         provider_slug: provider.slug,
         hosted_web_search?: provider.supports_hosted_web_search,
         kind: provider.kind,
         request_timeout_ms: provider.request_timeout_ms,
         max_concurrent_requests: provider.max_concurrent_requests,
         max_output_tokens: model.max_output_tokens
       }}
    end
  end

  ## What codex is told about a model

  @typedoc "`Longx.Codex.Thread.start/1` options derived from a model row."
  @type thread_options :: [
          {:model, String.t()}
          | {:model_context_window, pos_integer}
          | {:reasoning_effort, String.t()}
          | {:reasoning_summary, atom}
          | {:web_search, web_search_mode}
        ]

  @doc """
  The per-model options for starting (or forking) a codex thread: `nil` /
  `"longx"` is the global default model, whose name is *not* passed (codex
  keeps its placeholder); a slug names the model explicitly. Settings left
  unset on the model are absent, so codex's defaults apply. The web search
  mode is decided for this model, not the global default. (`max_output_tokens`
  is not codex's business: the gateway applies it, see `Longx.AI.Target`.)
  """
  @spec thread_options(String.t() | nil) ::
          {:ok, thread_options} | {:error, :no_default_model | {:unknown_model, String.t()}}
  def thread_options(slug) do
    with {:ok, model, explicit?} <- fetch_model(slug) do
      opts =
        []
        |> put_if(:model, explicit? && model.slug)
        |> Keyword.put(:model_context_window, model.context_window)
        |> put_if(:reasoning_effort, model.reasoning_effort)
        |> put_if(:reasoning_summary, model.reasoning_summary)
        |> Keyword.put(:web_search, web_search_mode(model))

      {:ok, Enum.reverse(opts)}
    end
  end

  @doc """
  The per-model options for a turn (`Longx.Codex.Thread.send/3`): the model
  to switch to (absent for the default) and its reasoning effort / summary,
  which codex applies from this turn on.
  """
  @spec turn_options(String.t() | nil) ::
          {:ok, keyword} | {:error, :no_default_model | {:unknown_model, String.t()}}
  def turn_options(slug) do
    with {:ok, model, explicit?} <- fetch_model(slug) do
      opts =
        []
        |> put_if(:model, explicit? && model.slug)
        |> put_if(:effort, model.reasoning_effort)
        |> put_if(:summary, model.reasoning_summary)

      {:ok, Enum.reverse(opts)}
    end
  end

  # {:ok, model, named explicitly?}
  defp fetch_model(nil), do: fetch_model(@placeholder_model)

  defp fetch_model(@placeholder_model) do
    with {:ok, model} <- fetch_default_model(), do: {:ok, model, false}
  end

  defp fetch_model(slug) when is_binary(slug) do
    case get_model_by_slug(slug) do
      {:ok, %Model{} = model} -> {:ok, model, true}
      {:error, _} -> {:error, {:unknown_model, slug}}
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, _key, false), do: opts
  defp put_if(opts, key, value), do: [{key, value} | opts]

  ## Health check

  # enough for the model to answer "ok"; keeps the check cheap
  @check_max_output_tokens 16
  @check_timeout :timer.seconds(30)

  @doc """
  Sends one tiny non-streaming Responses request through the model's provider
  and records the outcome on the provider (`last_checked_at`, `last_error`).
  Answers `{:ok, %{latency_ms: n}}`, `{:error, {:status, code, message}}`
  (the upstream refused), `{:error, {:unreachable, reason}}`, or the usual
  configuration errors before any request is made.
  """
  @spec check_model(Model.t() | String.t()) ::
          {:ok, %{latency_ms: non_neg_integer}} | {:error, term}
  def check_model(%Model{} = model) do
    with {:ok, %Target{} = target} <- target_for(model),
         {:ok, provider} <- get_provider_by_slug(target.provider_slug) do
      result = probe(target)
      {:ok, _} = record_provider_check(provider, check_error(result))
      result
    end
  end

  def check_model(slug) when is_binary(slug) do
    case get_model_by_slug(slug) do
      {:ok, %Model{} = model} -> check_model(model)
      {:error, _} -> {:error, {:unknown_model, slug}}
    end
  end

  defp probe(%Target{} = target) do
    started = System.monotonic_time(:millisecond)

    request =
      Req.new(
        url: String.trim_trailing(target.base_url, "/") <> "/responses",
        auth: {:bearer, target.api_key},
        json: %{
          model: target.model,
          input: "Reply with the single word: ok",
          max_output_tokens: @check_max_output_tokens,
          stream: false,
          store: false
        },
        retry: false,
        receive_timeout: @check_timeout
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, %{latency_ms: System.monotonic_time(:millisecond) - started}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:status, status, error_message(body)}}

      {:error, exception} ->
        {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp error_message(body), do: body |> inspect() |> String.slice(0, 500)

  defp check_error({:ok, _}), do: nil
  defp check_error({:error, {:status, status, message}}), do: "#{status} #{message}"
  defp check_error({:error, {:unreachable, reason}}), do: "unreachable: #{reason}"

  @doc "The web-search backend for codex's `web.run` tool: the default search provider and its key."
  @spec resolve_search_target() ::
          {:ok, SearchTarget.t()} | {:error, :no_search_provider | {:missing_api_key, String.t()}}
  def resolve_search_target do
    with {:ok, %SearchProvider{} = sp} <- fetch_default_search_provider(),
         %SearchProvider{} = sp <- Ash.load!(sp, :api_key),
         {:ok, api_key} <- fetch_api_key(sp) do
      {:ok,
       %SearchTarget{
         kind: sp.kind,
         base_url: sp.base_url,
         api_key: api_key,
         provider_slug: sp.slug
       }}
    end
  end

  @doc "Whether codex should be offered web search at all."
  @spec search_configured?() :: boolean
  def search_configured?, do: match?({:ok, _}, resolve_search_target())

  @typedoc """
  How codex should do web search, decided from what is configured:

    * `:hosted` — the upstream runs the Responses API's built-in `web_search`
      tool itself (OpenAI); nothing for us to do
    * `:standalone` — codex's `web.run` tool, executed by our `/alpha/search`
      against the default `SearchProvider`
    * `:disabled` — no search tool offered at all
  """
  @type web_search_mode :: :hosted | :standalone | :disabled

  @doc "See `t:web_search_mode/0`, for the global default model. `Longx.Codex.Home` writes it into codex's config."
  @spec web_search_mode() :: web_search_mode
  def web_search_mode, do: web_search_mode(resolve_target(), resolve_search_target())

  @doc """
  The web search mode for one model (by slug; `nil`/`"longx"` = the default),
  what a thread started on that model gets as config override. An unknown
  slug has nothing hosted to offer, so what is left applies.
  """
  @spec web_search_mode(String.t() | nil | Model.t()) :: web_search_mode
  def web_search_mode(%Model{} = model),
    do: web_search_mode(target_for(model), resolve_search_target())

  def web_search_mode(slug), do: web_search_mode(resolve_target(slug), resolve_search_target())

  defp web_search_mode({:ok, %Target{hosted_web_search?: true}}, _search), do: :hosted
  defp web_search_mode(_target, {:ok, %SearchTarget{}}), do: :standalone
  defp web_search_mode(_target, _search), do: :disabled

  defp fetch_default_search_provider do
    case default_search_provider() do
      {:ok, nil} -> {:error, :no_search_provider}
      other -> other
    end
  end

  defp fetch_default_model do
    case default_model() do
      {:ok, nil} -> {:error, :no_default_model}
      other -> other
    end
  end

  defp fetch_api_key(%{api_key: key}) when is_binary(key) and key != "", do: {:ok, key}
  defp fetch_api_key(%{slug: slug}), do: {:error, {:missing_api_key, slug}}
end
