defmodule Longx.AI do
  @moduledoc """
  Model providers, models, and the "which upstream do we talk to" decision
  used by the AI gateway. Codex only knows a placeholder model (`longx`);
  this domain decides what that means.
  """

  use Ash.Domain, otp_app: :longx

  alias Longx.AI.{Model, Provider, SearchProvider, SearchTarget, Target}
  alias Longx.Codex.Tool.Registry

  resources do
    resource Provider do
      define :create_provider, action: :create
      define :update_provider, action: :update
      define :list_providers, action: :read
      define :get_provider_by_slug, action: :by_slug, args: [:slug]
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
         kind: provider.kind
       }}
    end
  end

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

  @doc "See `t:web_search_mode/0`. Used by `Longx.Codex.Home` when writing codex's config."
  @spec web_search_mode() :: web_search_mode
  def web_search_mode, do: web_search_mode(resolve_target(), resolve_search_target())

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
