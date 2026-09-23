defmodule Longx.AI.Target do
  @moduledoc """
  Everything the gateway needs to forward one request upstream: resolved from
  the default `Longx.AI.Model` and its provider. Never logged whole — it
  carries the decrypted API key.
  """

  @enforce_keys [:model, :base_url, :api_key, :context_window]
  defstruct [
    :model,
    # the row's slug — what the person and the chain call it (the upstream id above is what the provider hears)
    :slug,
    :base_url,
    :api_key,
    :context_window,
    :provider_slug,
    hosted_web_search?: false,
    # the provider's hosted image_generation tool is offered
    image_generation?: false,
    # requests carry `prompt_cache_key` (the thread): OpenAI caches the prefix per key
    prompt_cache_key?: false,
    # :openai is the only provider whose reasoning items may be replayed to it
    # with their encrypted_content (see Longx.AI.Gateway)
    kind: :openai_compatible,
    request_timeout_ms: 600_000,
    stream_idle_timeout_ms: 300_000,
    max_concurrent_requests: nil,
    max_output_tokens: nil,
    # a ChatGPT subscription through the Codex backend: the key is an OAuth access
    # token, the request carries the account id and the backend's headers
    chatgpt?: false,
    account_id: nil,
    # the row's reasoning summary (auto / concise / detailed / none); nil = the
    # kernel's auto. Only OpenAI's hidden-reasoning models read it
    reasoning_summary: nil,
    # OpenAI's text.verbosity (low / medium / high); nil = not sent
    verbosity: nil
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          slug: String.t() | nil,
          base_url: String.t(),
          api_key: String.t(),
          context_window: pos_integer,
          provider_slug: String.t() | nil,
          hosted_web_search?: boolean,
          image_generation?: boolean,
          prompt_cache_key?: boolean,
          kind: :openai | :openai_compatible,
          request_timeout_ms: pos_integer,
          stream_idle_timeout_ms: pos_integer,
          max_concurrent_requests: pos_integer | nil,
          max_output_tokens: pos_integer | nil,
          chatgpt?: boolean,
          account_id: String.t() | nil,
          reasoning_summary: :auto | :concise | :detailed | :none | nil,
          verbosity: String.t() | nil
        }

  defimpl Inspect do
    def inspect(target, _opts), do: "#Longx.AI.Target<#{target.provider_slug}/#{target.model}>"
  end
end
