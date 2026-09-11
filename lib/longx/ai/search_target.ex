defmodule Longx.AI.SearchTarget do
  @moduledoc "Resolved web-search backend for `Longx.AI.Search`; carries the decrypted key, never log it whole."

  @enforce_keys [:kind, :base_url, :api_key]
  defstruct [:kind, :base_url, :api_key, :provider_slug]

  @type t :: %__MODULE__{
          kind: :tavily,
          base_url: String.t(),
          api_key: String.t(),
          provider_slug: String.t() | nil
        }

  defimpl Inspect do
    def inspect(target, _opts),
      do: "#Longx.AI.SearchTarget<#{target.kind}/#{target.provider_slug}>"
  end
end
