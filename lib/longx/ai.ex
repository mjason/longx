defmodule Longx.AI do
  @moduledoc """
  Model providers, models, and the "which upstream do we talk to" decision
  used by the AI gateway. Codex only knows a placeholder model (`longx`);
  this domain decides what that means.
  """

  use Ash.Domain, otp_app: :longx

  alias Longx.AI.{Model, Provider, SearchProvider, SearchTarget, Target}

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
  end

  @doc """
  The upstream the gateway should forward to right now: the default model
  plus its provider's base URL and decrypted key.
  """
  @spec resolve_target() ::
          {:ok, Target.t()} | {:error, :no_default_model | {:missing_api_key, String.t()}}
  def resolve_target do
    with {:ok, %Model{} = model} <- fetch_default_model(),
         %Model{provider: %Provider{} = provider} <- Ash.load!(model, provider: [:api_key]),
         {:ok, api_key} <- fetch_api_key(provider) do
      {:ok,
       %Target{
         model: model.upstream_id,
         base_url: provider.base_url,
         api_key: api_key,
         context_window: model.context_window,
         provider_slug: provider.slug,
         hosted_web_search?: provider.supports_hosted_web_search
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
