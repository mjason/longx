defmodule Longx.AI do
  @moduledoc """
  Model providers, models, and the "which upstream do we talk to" decision
  used by the AI gateway. Codex only knows a placeholder model (`longx`);
  this domain decides what that means.
  """

  use Ash.Domain, otp_app: :longx

  alias Longx.AI.{Model, Provider, Target}

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
         provider_slug: provider.slug
       }}
    end
  end

  defp fetch_default_model do
    case default_model() do
      {:ok, nil} -> {:error, :no_default_model}
      other -> other
    end
  end

  defp fetch_api_key(%Provider{api_key: key}) when is_binary(key) and key != "", do: {:ok, key}
  defp fetch_api_key(%Provider{slug: slug}), do: {:error, {:missing_api_key, slug}}
end
