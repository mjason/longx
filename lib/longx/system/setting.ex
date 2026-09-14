defmodule Longx.System.Setting do
  @moduledoc """
  A node-wide key → value the settings page edits and nothing else reads
  back: the value is encrypted at rest like a provider's API key (the first
  use is the GitHub token `Longx.Upgrade` sends to avoid the API rate limit).
  Not on the RPC surface — `Longx.System.put_setting/2` / `get_setting/1`
  are the API, and a "has a value" answer is all the client ever gets.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.System,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCloak]

  sqlite do
    table "system_settings"
    repo Longx.Repo
  end

  cloak do
    vault(Longx.Vault)
    attributes([:value])
    decrypt_by_default([:value])
    encrypt_nil?(false)
  end

  actions do
    defaults [:read, :destroy]

    create :put do
      primary? true
      accept [:key, :value]
      upsert? true
      upsert_fields [:value]
    end

    read :by_key do
      argument :key, :string, allow_nil?: false
      get? true
      filter expr(key == ^arg(:key))
    end
  end

  attributes do
    attribute :key, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :value, :string, sensitive?: true, public?: true
    timestamps()
  end
end
