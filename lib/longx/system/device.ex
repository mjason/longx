defmodule Longx.System.Device do
  @moduledoc """
  A phone paired with this Longx (Settings → 移动端). Its token — shown
  once, at pairing — is the bearer the app puts on every RPC, upload and
  socket in place of the browser's session + CSRF; only its sha256 is
  kept. Revoking the row ends the token.
  """

  use Ash.Resource,
    otp_app: :longx,
    domain: Longx.System,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "system_devices"
    repo Longx.Repo
  end

  typescript do
    type_name "Device"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :platform, :token_hash]
    end

    update :seen do
      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end

    read :by_token_hash do
      argument :token_hash, :string, allow_nil?: false
      get? true
      filter expr(token_hash == ^arg(:token_hash))
    end

    read :list do
      prepare build(sort: [inserted_at: :desc])
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :platform, :atom,
      constraints: [one_of: [:android, :ios, :other]],
      default: :other,
      allow_nil?: false,
      public?: true

    attribute :token_hash, :string, allow_nil?: false, sensitive?: true
    attribute :last_seen_at, :utc_datetime_usec, public?: true
    timestamps public?: true
  end

  identities do
    identity :unique_token_hash, [:token_hash]
  end
end
