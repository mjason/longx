defmodule Longx.AI.Target do
  @moduledoc """
  Everything the gateway needs to forward one request upstream: resolved from
  the default `Longx.AI.Model` and its provider. Never logged whole — it
  carries the decrypted API key.
  """

  @enforce_keys [:model, :base_url, :api_key, :context_window]
  defstruct [
    :model,
    :base_url,
    :api_key,
    :context_window,
    :provider_slug,
    hosted_web_search?: false
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          base_url: String.t(),
          api_key: String.t(),
          context_window: pos_integer,
          provider_slug: String.t() | nil,
          hosted_web_search?: boolean
        }

  defimpl Inspect do
    def inspect(target, _opts), do: "#Longx.AI.Target<#{target.provider_slug}/#{target.model}>"
  end
end
